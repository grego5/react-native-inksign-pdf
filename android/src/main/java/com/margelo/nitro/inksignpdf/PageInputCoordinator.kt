package com.margelo.nitro.inksignpdf

import android.content.Context
import android.app.Activity
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.facebook.react.bridge.ReactContext
import com.margelo.nitro.NitroModules
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import java.util.concurrent.atomic.AtomicLong

internal interface PagePickerHandle {
  fun launch(intent: Intent)
  fun unregister()
}

internal fun interface PagePickerRegistrar {
  fun register(token: Any, callback: (ActivityResult) -> Unit): PagePickerHandle
}

/** One staged source owned by the native page-input boundary. */
internal data class StagedPageInput(
  val file: File,
  val type: PageType,
)

internal enum class PageType { PDF, IMAGE }

/**
 * Owns native selection and source staging for one document.
 *
 * The coordinator is main-thread-owned for request state.
 * File copying and image validation run on I/O, and all completed files are
 * returned as module-owned artifacts for the document coordinator to consume.
 */
internal class PageInputCoordinator(
  private val context: Context,
  private val artifactPolicy: CacheArtifactPolicy,
  private val sourceOpener: ((Uri) -> InputStream?)? = null,
  private val pickerRegistrar: PagePickerRegistrar? = null,
) : AutoCloseable {
  private val resolver = context.contentResolver
  private var disposed = false
  private var activeRequest: Request? = null
  private var selectionClosed = false

  suspend fun stage(sources: Array<String>?, type: PageInputType? = null): List<StagedPageInput> = withRequest { request ->
    val requestedType = when (type) {
      PageInputType.PDF -> PageType.PDF
      PageInputType.IMAGE -> PageType.IMAGE
      null -> null
    }
    val selected = sources?.toList() ?: run {
      if (selectionClosed) throw cancelled()
      awaitPicker(request, requestedType).map(Uri::toString)
    }
    stageSources(request, selected, requestedType)
  }

  private suspend fun <T> withRequest(action: suspend (Request) -> T): T {
    checkMainThread()
    if (disposed) throw cancelled()
    if (activeRequest != null) throw inProgress()

    val request = Request()
    activeRequest = request
    var completed = false
    try {
      return action(request).also { completed = true }
    } finally {
      try { if (!completed) cleanup(request) }
      finally {
        finishPicker(request)
        if (activeRequest === request) activeRequest = null
      }
    }
  }

  /** Releases successfully staged files after the document worker consumes them. */
  suspend fun release(staged: Collection<StagedPageInput>) = withContext(Dispatchers.IO) {
    staged.forEach { artifactPolicy.deleteExact(it.file) }
  }

  /** Cancels the active source-copy operation on main. */
  fun cancelPending() {
    checkMainThread()
    activeRequest?.let { request -> synchronized(request) { request.cancelled = true } }
    activeRequest?.let(::cancelWaiting)
  }

  /** Close admission cancels waiting UI, while selected/direct imports may drain. */
  fun cancelSelection() {
    checkMainThread()
    selectionClosed = true
    activeRequest?.let(::cancelWaiting)
  }

  private fun cancelWaiting(request: Request) {
    val continuation = request.pickerContinuation ?: return
    request.pickerContinuation = null
    request.cancelled = true
    finishPicker(request)
    if (continuation.isActive) continuation.resumeWithException(cancelled())
  }

  private fun finishPicker(request: Request) {
    request.picker?.unregister()
    request.picker = null
    if (pickerOwner === request) pickerOwner = null
  }

  private suspend fun awaitPicker(request: Request, type: PageType?): List<Uri> =
    suspendCancellableCoroutine { continuation ->
      if (pickerOwner != null) {
        continuation.resumeWithException(inProgress())
        return@suspendCancellableCoroutine
      }
      pickerOwner = request
      request.pickerContinuation = continuation
      continuation.invokeOnCancellation {
        android.os.Handler(android.os.Looper.getMainLooper()).post { cancelWaiting(request) }
      }
      try {
        val handle = pickerRegistrar?.register(request) { handlePickerResult(request, it) }
          ?: registerPicker(request)
        if (request.pickerContinuation == null) { handle.unregister(); return@suspendCancellableCoroutine }
        request.picker = handle
        handle.launch(buildPagePickerIntent(type))
      } catch (error: Throwable) {
        request.pickerContinuation = null
        finishPicker(request)
        if (continuation.isActive) continuation.resumeWithException(
          if (error is PdfSessionException) error else PdfSessionException("picker_unavailable", "The system input picker could not be opened"))
      }
    }

  private fun registerPicker(request: Request): PagePickerHandle {
    val react = context as? ReactContext ?: NitroModules.applicationContext
    val activity = react?.currentActivity as? ComponentActivity
      ?: throw PdfSessionException("missing_presenter", "A foreground activity is required to choose inputs")
    if (activity.isFinishing || activity.isDestroyed ||
        !activity.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
      throw PdfSessionException("missing_presenter", "A foreground activity is required to choose inputs")
    }
    val observer = LifecycleEventObserver { _, event ->
      if (event == Lifecycle.Event.ON_DESTROY) cancelWaiting(request)
    }
    val launcher = activity.activityResultRegistry.register(
      "inksignpdf.inputs.${launcherIds.incrementAndGet()}",
      ActivityResultContracts.StartActivityForResult(),
    ) { handlePickerResult(request, it) }
    activity.lifecycle.addObserver(observer)
    return object : PagePickerHandle {
      override fun launch(intent: Intent) = launcher.launch(intent)
      override fun unregister() {
        launcher.unregister()
        activity.lifecycle.removeObserver(observer)
      }
    }
  }

  private fun handlePickerResult(request: Request, result: ActivityResult) {
    checkMainThread()
    if (activeRequest !== request) return
    val continuation = request.pickerContinuation ?: return
    request.pickerContinuation = null
    finishPicker(request)
    if (!continuation.isActive) return
    when (result.resultCode) {
      Activity.RESULT_CANCELED -> continuation.resume(emptyList())
      Activity.RESULT_OK -> {
        val sources = extractOrderedUris(result.data)
        if (sources == null) continuation.resumeWithException(
          PdfSessionException("malformed_picker_result", "The native picker returned no sources"))
        else continuation.resume(sources)
      }
      else -> continuation.resumeWithException(
        PdfSessionException("malformed_picker_result", "The native picker returned an invalid result"))
    }
  }

  override fun close() {
    checkMainThread()
    if (disposed) return
    disposed = true
    cancelPending()
  }

  private suspend fun stageSources(
    request: Request,
    sources: List<String>,
    requestedType: PageType?,
  ): List<StagedPageInput> = withContext(Dispatchers.IO) {
    buildList {
      sources.forEach { source ->
        coroutineContext.ensureActive()
        add(stageOne(request, requestedType, source))
      }
    }
  }

  private suspend fun stageOne(
    request: Request,
    requestedType: PageType?,
    sourceDescription: String,
  ): StagedPageInput {
    ensureActive(request)
    val staged = artifactPolicy.allocateStagedInput()
    var retained = false
    try {
      val detectedType = copySource(request, sourceDescription, staged)
      if (requestedType != null && requestedType != detectedType) {
        throw PdfSessionException(
          "unsupported_content",
          "The selected source is not a ${requestedType.name.lowercase()}",
        )
      }
      synchronized(request) {
        ensureActiveLocked(request)
        request.staged += staged
        retained = true
      }
      return StagedPageInput(staged, detectedType)
    } finally {
      if (!retained) artifactPolicy.deleteExact(staged)
    }
  }

  private suspend fun copySource(request: Request, sourceDescription: String, destination: File): PageType {
    try {
      ensureActive(request)
      openSource(sourceDescription).use { source ->
        destination.outputStream().buffered().use { output ->
          copyWithCancellation(request, source, output)
        }
      }
      val type = detectType(destination, sourceDescription)
      ensureActive(request)
      return type
    } catch (error: PdfSessionException) {
      throw error
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      throw unreadableSource(sourceDescription, error)
    }
  }

  private suspend fun copyWithCancellation(
    request: Request,
    input: InputStream,
    output: java.io.OutputStream,
  ) {
    val buffer = ByteArray(COPY_BUFFER_BYTES)
    val context = currentCoroutineContext()
    while (true) {
      context.ensureActive()
      ensureActive(request)
      val count = input.read(buffer)
      if (count < 0) return
      context.ensureActive()
      ensureActive(request)
      output.write(buffer, 0, count)
    }
  }

  private fun openSource(raw: String): InputStream {
    if (raw.isBlank()) throw PdfSessionException("unsupported_source", "Source path is blank")
    val uri = try {
      Uri.parse(raw)
    } catch (error: RuntimeException) {
      throw unreadableSource(raw, error)
    }
    val file = when (uri.scheme?.lowercase()) {
      null, "" -> File(raw)
      "file" -> uri.path?.let(::File)
        ?: throw unreadableSource(raw)
      "content", "android.resource" -> return sourceOpener?.invoke(uri)
        ?: resolver.openInputStream(uri) ?: throw unreadableSource(raw)
      else -> throw PdfSessionException(
        "unsupported_source",
        "Only local paths, file URLs, and Android content/resource URIs are supported",
      )
    }
    if (!file.isFile || !file.canRead()) throw unreadableSource(raw)
    return FileInputStream(file)
  }

  private fun detectType(file: File, sourceDescription: String): PageType {
    val pdfHeader = ByteArray(PDF_HEADER_BYTES)
    val read = try {
      FileInputStream(file).use { it.read(pdfHeader) }
    } catch (error: Exception) {
      throw unreadableSource(sourceDescription, error)
    }
    if (read >= 5 && String(pdfHeader, 0, 5, Charsets.US_ASCII) == "%PDF-") {
      return PageType.PDF
    }

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.absolutePath, bounds)
    if (bounds.outWidth > 0 && bounds.outHeight > 0) return PageType.IMAGE
    throw PdfSessionException(
      "unsupported_content",
      "The selected source is not a readable PDF or image",
    )
  }

  private suspend fun cleanup(request: Request) = withContext(NonCancellable + Dispatchers.IO) {
    val files = synchronized(request) {
      request.staged.toList().also { request.staged.clear() }
    }
    files.forEach(artifactPolicy::deleteExact)
  }

  private fun ensureActive(request: Request) {
    synchronized(request) { ensureActiveLocked(request) }
  }

  private fun ensureActiveLocked(request: Request) {
    if (request.cancelled || disposed) throw cancelled()
  }


  private fun checkMainThread() {
    check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
  }

  private fun cancelled() = PdfSessionException(
    "operation_cancelled",
    "Page source staging was cancelled",
  )

  private fun inProgress() = PdfSessionException(
    "operation_in_progress",
    "Another page source operation is already active",
  )

  private fun unreadableSource(source: String, cause: Throwable? = null) = PdfSessionException(
    "unreadable_source",
    "Unable to read page source: $source",
    cause,
  )

  private class Request {
    @Volatile var cancelled = false
    val staged = mutableListOf<File>()
    var pickerContinuation: CancellableContinuation<List<Uri>>? = null
    var picker: PagePickerHandle? = null
  }

  companion object {
    private var pickerOwner: Any? = null
    private val launcherIds = AtomicLong()
    internal fun buildPagePickerIntent(type: PageType?): Intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
      this.type = when (type) { PageType.PDF -> "application/pdf"; PageType.IMAGE -> "image/*"; null -> "*/*" }
      if (type == null) putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/pdf", "image/*"))
    }
    internal fun extractOrderedUris(intent: Intent?): List<Uri>? {
      val uris = linkedSetOf<Uri>()
      intent?.clipData?.let { clip -> for (index in 0 until clip.itemCount) uris += clip.getItemAt(index).uri }
      intent?.data?.let(uris::add)
      return uris.toList().takeIf { it.isNotEmpty() }
    }
    private const val PDF_HEADER_BYTES = 8
    private const val COPY_BUFFER_BYTES = 64 * 1024
  }
}
