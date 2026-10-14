package com.margelo.nitro.inksignpdf

import android.content.Context
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

/** One staged source owned by the native page-input boundary. */
internal data class StagedPageInput(
  val file: File,
  val type: PageType,
)

internal enum class PageType { PDF, IMAGE }

/**
 * Owns explicit source staging for one document.
 *
 * The coordinator is main-thread-owned for request state.
 * File copying and image validation run on I/O, and all completed files are
 * returned as module-owned artifacts for the document coordinator to consume.
 */
internal class PageInputCoordinator(
  private val context: Context,
  private val artifactPolicy: CacheArtifactPolicy,
  private val sourceOpener: ((Uri) -> InputStream?)? = null,
) : AutoCloseable {
  private val resolver = context.contentResolver
  private var disposed = false
  private var activeRequest: Request? = null

  /** Writes a borrowed destination; its caller owns retention and retirement. */
  suspend fun copyInto(source: String, destination: File): PageType = withRequest { request ->
    withContext(Dispatchers.IO) { copySource(request, source, destination) }
  }

  suspend fun stage(sources: Array<String>): List<StagedPageInput> = withRequest { request ->
    stageSources(request, sources.toList(), null)
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
      finally { if (activeRequest === request) activeRequest = null }
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
  }

  companion object {
    private const val PDF_HEADER_BYTES = 8
    private const val COPY_BUFFER_BYTES = 64 * 1024
  }
}
