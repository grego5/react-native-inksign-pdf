package com.margelo.nitro.inksignpdf

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import com.facebook.react.bridge.ReactContext
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.util.LinkedHashSet
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** One staged source owned by the native page-input boundary. */
internal data class StagedPageInput(
  val file: File,
  val type: PageType,
)

internal interface PagePickerHandle {
  fun launch(intent: Intent)

  fun unregister()
}

internal fun interface PagePickerRegistrar {
  fun register(token: Any, callback: (ActivityResult) -> Unit): PagePickerHandle
}

/**
 * Owns Android picker presentation and source staging for one native view.
 *
 * The coordinator is main-thread-owned for request state and picker callbacks.
 * File copying and image validation run on I/O, and all completed files are
 * returned as module-owned artifacts for the document coordinator to consume.
 */
internal class AndroidPageInputCoordinator(
  private val context: Context,
  private val artifactPolicy: CacheArtifactPolicy,
  private val pickerRegistrar: PagePickerRegistrar? = null,
  private val sourceOpener: ((Uri) -> InputStream?)? = null,
) : AutoCloseable {
  private val resolver = context.contentResolver
  private var disposed = false
  private var activeRequest: Request? = null

  suspend fun stage(options: AddPagesOptions?): List<StagedPageInput> {
    checkMainThread()
    if (disposed) throw cancelled()
    if (activeRequest != null) throw inProgress()

    val request = Request()
    activeRequest = request
    var completed = false
    try {
      val staged = if (options?.sources != null) {
        stageSources(request, options.sources.toList(), options.type)
      } else {
        val uris = awaitPicker(request, options?.type)
        stageUris(request, uris, options?.type)
      }
      completed = true
      return staged.toList()
    } finally {
      if (!completed) cleanup(request)
      if (activeRequest === request) activeRequest = null
    }
  }

  /** Releases successfully staged files after the document worker consumes them. */
  suspend fun release(staged: Collection<StagedPageInput>) = withContext(Dispatchers.IO) {
    staged.forEach { artifactPolicy.deleteExact(it.file) }
  }

  /** Cancels the active picker or source-copy operation. Must run on main. */
  fun cancelPending() {
    checkMainThread()
    val request = activeRequest ?: return
    val (continuation, picker) = synchronized(request) {
      request.cancelled = true
      Pair(
        request.pickerContinuation.also { request.pickerContinuation = null },
        request.picker.also { request.picker = null },
      )
    }
    picker?.unregister()
    continuation?.resumeWithException(cancelled())
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
        add(stageOne(request, requestedType, source) { openLocalSource(source) })
      }
    }
  }

  private suspend fun stageUris(
    request: Request,
    uris: List<Uri>,
    requestedType: PageType?,
  ): List<StagedPageInput> = withContext(Dispatchers.IO) {
    buildList {
      uris.forEach { uri ->
        coroutineContext.ensureActive()
        add(stageOne(request, requestedType, uri.toString()) {
          sourceOpener?.invoke(uri) ?: try {
            resolver.openInputStream(uri)
          } catch (error: SecurityException) {
            throw unreadableSource(uri.toString(), error)
          }
        })
      }
    }
  }

  private suspend fun stageOne(
    request: Request,
    requestedType: PageType?,
    sourceDescription: String,
    open: () -> InputStream?,
  ): StagedPageInput {
    ensureActive(request)
    val staged = artifactPolicy.allocateStagedInput()
    try {
      val input = try {
        open() ?: throw unreadableSource(sourceDescription)
      } catch (error: PdfSessionException) {
        throw error
      } catch (error: SecurityException) {
        throw unreadableSource(sourceDescription, error)
      } catch (error: Exception) {
        throw unreadableSource(sourceDescription, error)
      }
      input.use { source ->
        staged.outputStream().buffered().use { destination ->
          copyWithCancellation(request, source, destination)
        }
      }

      val detectedType = detectType(staged, sourceDescription)
      if (requestedType != null && requestedType != detectedType) {
        throw PdfSessionException(
          "unsupported_content",
          "The selected source is not a ${requestedType.name.lowercase()}",
        )
      }
      synchronized(request) {
        ensureActiveLocked(request)
        request.staged += staged
      }
      return StagedPageInput(staged, detectedType)
    } catch (error: PdfSessionException) {
      artifactPolicy.deleteExact(staged)
      throw error
    } catch (error: CancellationException) {
      artifactPolicy.deleteExact(staged)
      throw error
    } catch (error: Exception) {
      artifactPolicy.deleteExact(staged)
      throw unreadableSource(sourceDescription, error)
    }
  }

  private suspend fun copyWithCancellation(
    request: Request,
    input: InputStream,
    output: java.io.OutputStream,
  ) {
    val buffer = ByteArray(COPY_BUFFER_BYTES)
    while (true) {
      coroutineContext.ensureActive()
      ensureActive(request)
      val count = input.read(buffer)
      if (count < 0) return
      coroutineContext.ensureActive()
      ensureActive(request)
      output.write(buffer, 0, count)
    }
  }

  private fun openLocalSource(raw: String): InputStream {
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
      else -> throw PdfSessionException(
        "unsupported_source",
        "Only local paths and file URLs are supported as direct sources",
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

  private suspend fun awaitPicker(
    request: Request,
    requestedType: PageType?,
  ): List<Uri> = suspendCancellableCoroutine { continuation ->
    val requestPicker = try {
      registerPicker(request)
    } catch (error: Throwable) {
      continuation.resumeWithException(error)
      return@suspendCancellableCoroutine
    }
    synchronized(request) {
      request.pickerContinuation = continuation
      request.picker = requestPicker
    }
    continuation.invokeOnCancellation {
      synchronized(request) {
        request.cancelled = true
        request.pickerContinuation = null
      }
      requestPicker.unregister()
    }
    try {
      requestPicker.launch(buildPickerIntent(requestedType))
    } catch (error: Throwable) {
      synchronized(request) {
        request.pickerContinuation = null
        request.picker = null
      }
      requestPicker.unregister()
      continuation.resumeWithException(
        PdfSessionException("picker_unavailable", "Unable to present the native file picker", error),
      )
    }
  }

  private fun registerPicker(request: Request): PagePickerHandle {
    pickerRegistrar?.let { registrar ->
      return registrar.register(request) { result -> handlePickerResult(request, result) }
    }
    val activity = (context as? ReactContext)?.currentActivity as? ComponentActivity
      ?: throw PdfSessionException(
        "missing_activity",
        "A foreground activity is required to choose page sources",
      )
    val key = "inksignpdf.page-input.${launcherIds.incrementAndGet()}"
    val registered: ActivityResultLauncher<Intent> = activity.activityResultRegistry.register(
      key,
      ActivityResultContracts.StartActivityForResult(),
    ) { result -> handlePickerResult(request, result) }
    return object : PagePickerHandle {
      override fun launch(intent: Intent) = registered.launch(intent)

      override fun unregister() = registered.unregister()
    }
  }

  private fun handlePickerResult(request: Request, result: ActivityResult) {
    checkMainThread()
    if (activeRequest !== request) {
      request.picker?.unregister()
      return
    }
    val settled = synchronized(request) {
      Pair(
        request.pickerContinuation.also { request.pickerContinuation = null },
        request.picker.also { request.picker = null },
      )
    }
    val continuation = settled.first ?: return
    val picker = settled.second
    picker?.unregister()
    if (request.cancelled || disposed) return
    if (result.resultCode == Activity.RESULT_CANCELED) {
      continuation.resume(emptyList())
      return
    }
    if (result.resultCode != Activity.RESULT_OK) {
      continuation.resumeWithException(
        PdfSessionException("malformed_picker_result", "The native picker returned an invalid result"),
      )
      return
    }
    val uris = extractOrderedUris(result.data)
    if (uris == null) {
      continuation.resumeWithException(
        PdfSessionException("malformed_picker_result", "The native picker returned no sources"),
      )
    } else {
      continuation.resume(uris)
    }
  }

  private suspend fun cleanup(request: Request) = withContext(Dispatchers.IO) {
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

  private fun buildPickerIntent(type: PageType?): Intent = buildPagePickerIntent(type)

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
    var pickerContinuation: CancellableContinuation<List<Uri>>? = null
    var picker: PagePickerHandle? = null
    val staged = mutableListOf<File>()
  }

  companion object {
    private const val PDF_HEADER_BYTES = 8
    private const val COPY_BUFFER_BYTES = 64 * 1024
    private val launcherIds = AtomicLong()

    internal fun buildPagePickerIntent(type: PageType?): Intent = Intent(
      Intent.ACTION_OPEN_DOCUMENT,
    ).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
      val mimeTypes = when (type) {
        PageType.PDF -> arrayOf("application/pdf")
        PageType.IMAGE -> arrayOf("image/*")
        null -> arrayOf("application/pdf", "image/*")
      }
      if (mimeTypes.size == 1) {
        this.type = mimeTypes[0]
      } else {
        this.type = "*/*"
        putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes)
      }
    }

    internal fun extractOrderedUris(intent: Intent?): List<Uri>? {
      if (intent == null) return null
      val ordered = LinkedHashSet<Uri>()
      intent.data?.let(ordered::add)
      intent.clipData?.let { clipData ->
        for (index in 0 until clipData.itemCount) {
          ordered += clipData.getItemAt(index).uri
        }
      }
      return ordered.takeIf { it.isNotEmpty() }
    }
  }
}
