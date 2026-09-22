package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.pdf.PdfRendererPreV
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory

internal const val pdfiumAndroidDisplayFlags = 0x13

/** Point dimensions reported by one page of an opened source PDF. */
internal data class PdfPageDimensions(
  val width: Double,
  val height: Double,
)

/** Metadata transferred from the PDF worker to the view owner. */
internal data class PdfSessionInfo(
  val sourcePath: String,
  val pages: List<PdfPageDimensions>,
  val generation: Long,
) {
  init {
    require(sourcePath.isNotEmpty())
    require(pages.isNotEmpty())
    require(pages.all { it.width.isFinite() && it.width > 0.0 &&
      it.height.isFinite() && it.height > 0.0 })
  }

  val pageCount: Int
    get() = pages.size
}

/** Stable open failures at the Android PDF boundary. */
internal class PdfSessionException(
  val code: String,
  message: String,
  cause: Throwable? = null,
) : IllegalStateException("$code: $message", cause)

/**
 * A worker-owned PDF resource. Implementations must only be used and closed
 * by the serial worker that created them.
 */
internal interface PdfSessionResource : AutoCloseable {
  val info: PdfSessionInfo

  /** Transfers the returned bitmaps to the caller; the worker no longer owns them. */
  fun renderTiles(
    requests: List<PdfTileRequest>,
    beforeEach: () -> Unit,
  ): List<PdfTile>

  /** Renders one presentation-only snapshot without changing tile epochs. */
  fun renderPreview(
    request: PdfTileRequest,
    beforeRender: () -> Unit,
  ): PdfTile
}

internal fun validatePdfTileBatch(
  info: PdfSessionInfo,
  requests: List<PdfTileRequest>,
) {
  if (requests.isEmpty()) return
  val pageIndex = requests.first().key.pageIndex
  if (pageIndex !in 0 until info.pageCount ||
    requests.any { it.key.pageIndex != pageIndex || it.key.pageIndex !in 0 until info.pageCount }
  ) {
    throw PdfSessionException(
      "invalid_tile_request",
      "A tile batch must contain one valid page index",
    )
  }
}

internal fun interface PdfSessionOpener {
  fun open(path: String, generation: Long): PdfSessionResource

  fun open(
    path: String,
    generation: Long,
    fallbackFont: PdfFallbackFont?,
  ): PdfSessionResource = open(path, generation)
}

/** Worker-owned Android PDF document session backed by one PDFium byte session. */
internal class PdfSession private constructor(
  override val info: PdfSessionInfo,
  private val pdfiumSession: PdfiumRenderSession,
) : PdfSessionResource {
  private var closed = false

  override fun close() {
    if (closed) return
    closed = true
    pdfiumSession.close()
  }

  override fun renderTiles(
    requests: List<PdfTileRequest>,
    beforeEach: () -> Unit,
  ): List<PdfTile> {
    validatePdfTileBatch(info, requests)
    if (requests.isEmpty()) return emptyList()
    val rendered = ArrayList<PdfTile>(requests.size)
    try {
      requests.forEach { request ->
        beforeEach()
        val bitmap = Bitmap.createBitmap(
          request.widthPx,
          request.heightPx,
          Bitmap.Config.ARGB_8888,
        )
        try {
          val renderedByPdfium = renderPdfiumTile(request, bitmap)
          check(renderedByPdfium) {
            "PDFium failed to render tile ${request.key}"
          }
          rendered += PdfTile(request, bitmap)
        } catch (error: Throwable) {
          bitmap.recycle()
          throw error
        }
      }
    } catch (error: Throwable) {
      rendered.forEach { it.bitmap.recycle() }
      throw error
    }
    return rendered
  }

  override fun renderPreview(
    request: PdfTileRequest,
    beforeRender: () -> Unit,
  ): PdfTile {
    val rendered = renderTiles(listOf(request), beforeRender)
    return checkNotNull(rendered.singleOrNull())
  }

  private fun renderPdfiumTile(request: PdfTileRequest, bitmap: Bitmap): Boolean {
    val scale = request.scale
    require(scale.isFinite() && scale > 0.0)
    val matrix = PdfiumAffineMatrix(
      a = scale,
      b = 0.0,
      c = 0.0,
      d = scale,
      e = -request.leftPx.toDouble(),
      f = -request.topPx.toDouble(),
    )
    return pdfiumSession.renderPageIntoBitmap(
      pageIndex = request.key.pageIndex,
      bitmap = bitmap,
      pageToDevice = matrix,
      clip = PdfiumRect(0.0, 0.0, request.widthPx.toDouble(), request.heightPx.toDouble()),
      background = 0xFFFFFFFF.toInt(),
      flags = pdfiumAndroidDisplayFlags,
    )
  }


  companion object : PdfSessionOpener {
    override fun open(path: String, generation: Long): PdfSessionResource {
      return open(path, generation, null)
    }

    override fun open(
      path: String,
      generation: Long,
      fallbackFont: PdfFallbackFont?,
    ): PdfSessionResource {
      PdfApiSupport.requireSupported()

      val source = try {
        File(path).canonicalFile
      } catch (error: IOException) {
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to resolve the PDF path",
          error,
        )
      } catch (error: SecurityException) {
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to resolve the PDF path",
          error,
        )
      }
      if (!source.isFile || !source.canRead()) {
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to read the PDF",
        )
      }

      val sourceBytes = try {
        source.readBytes()
      } catch (error: IOException) {
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to read the PDF bytes",
          error,
        )
      } catch (error: SecurityException) {
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to read the PDF bytes",
          error,
        )
      }

      var pdfiumSession: PdfiumRenderSession? = null
      try {
        val openedSession = PdfiumRenderSession.open(sourceBytes, fallbackFont)
        pdfiumSession = openedSession
        if (openedSession.pageCount <= 0) {
          throw PdfSessionException(
            "pdf_load_failed",
            "The PDF has no pages",
          )
        }

        val pages = ArrayList<PdfPageDimensions>(openedSession.pageCount)
        (0 until openedSession.pageCount).forEach { pageIndex ->
          val size = openedSession.pageSize(pageIndex)
          pages += PdfPageDimensions(size.width, size.height)
        }
        return PdfSession(
          info = PdfSessionInfo(source.path, pages, generation),
          pdfiumSession = openedSession,
        )
      } catch (error: PdfSessionException) {
        pdfiumSession?.close()
        throw error
      } catch (error: SecurityException) {
        pdfiumSession?.close()
        throw PdfSessionException(
          "unsupported_pdf",
          "The PDF is protected or uses an unsupported security scheme",
          error,
        )
      } catch (error: IllegalStateException) {
        pdfiumSession?.close()
        throw PdfSessionException(
          "pdfium_open_failed",
          error.message ?: "PDFium document open failed",
          error,
        )
      } catch (error: Exception) {
        pdfiumSession?.close()
        throw PdfSessionException(
          "pdf_load_failed",
          "Unable to load the PDF",
          error,
        )
      }
    }

  }
}

/** Closes a partially opened PDF without closing a descriptor twice. */
internal fun closeFailedPdfResources(
  renderer: PdfRendererPreV?,
  descriptor: ParcelFileDescriptor,
  temporarySource: File? = null,
) {
  try {
    if (renderer != null) renderer.close() else descriptor.close()
  } finally {
    temporarySource?.delete()
  }
}

/**
 * Serializes all PDF session work and keeps every session resource on its
 * owning worker. A newer generation invalidates an in-flight open before its
 * candidate session can become current; independent tile and preview epochs
 * stop stale same-document work before the next allocation/render.
 */
internal class PdfSessionWorker(
  private val opener: PdfSessionOpener = PdfSession,
  threadFactory: ThreadFactory = PdfWorkerThreadFactory,
) : AutoCloseable {
  private val executor: ExecutorService = Executors.newSingleThreadExecutor(threadFactory)
  private val stateLock = Any()
  private var current: PdfSessionResource? = null
  @Volatile private var requestedGeneration = Long.MIN_VALUE
  @Volatile private var requestedTileEpoch = Long.MIN_VALUE
  @Volatile private var requestedPreviewEpoch = Long.MIN_VALUE
  @Volatile private var closed = false

  fun replace(
    path: String,
    generation: Long,
    fallbackFont: PdfFallbackFont?,
    completion: (Result<PdfSessionInfo>) -> Unit,
  ) {
    replaceInternal(path, generation, fallbackFont, completion)
  }

  fun replace(
    path: String,
    generation: Long,
    completion: (Result<PdfSessionInfo>) -> Unit,
  ) {
    replaceInternal(path, generation, null, completion)
  }

  /** Applies one transactional PDFium mutation and installs its candidate session. */
  fun mutate(
    workingPath: String,
    candidatePath: String,
    generation: Long,
    request: PdfiumAssemblyRequest,
    fallbackFont: PdfFallbackFont?,
    retireCandidate: (File) -> Unit,
    completion: (Result<PdfSessionInfo>) -> Unit,
  ) {
    val rejected = synchronized(stateLock) {
      if (closed) {
        true
      } else {
        requestedGeneration = generation
        try {
          executor.execute {
            mutateOnWorker(
              workingPath,
              candidatePath,
              generation,
              request,
              fallbackFont,
              retireCandidate,
              completion,
            )
          }
          false
        } catch (_: java.util.concurrent.RejectedExecutionException) {
          true
        }
      }
    }
    if (rejected) {
      retireCandidate(File(candidatePath))
      completion(Result.failure(cancelled(generation)))
    }
  }

  private fun replaceInternal(
    path: String,
    generation: Long,
    fallbackFont: PdfFallbackFont?,
    completion: (Result<PdfSessionInfo>) -> Unit,
  ) {
    val rejected = synchronized(stateLock) {
      if (closed) {
        true
      } else {
        requestedGeneration = generation
        requestedTileEpoch = Long.MIN_VALUE
        requestedPreviewEpoch = Long.MIN_VALUE
        try {
          executor.execute {
            replaceOnWorker(path, generation, fallbackFont, completion)
          }
          false
        } catch (_: java.util.concurrent.RejectedExecutionException) {
          true
        }
      }
    }
    if (rejected) {
      completion(Result.failure(cancelled(generation)))
    }
  }

  fun renderTiles(
    generation: Long,
    tileEpoch: Long,
    requests: List<PdfTileRequest>,
    completion: (Result<List<PdfTile>>) -> Unit,
  ) {
    if (closed) {
      completion(Result.failure(cancelled(generation)))
      return
    }
    try {
        executor.execute {
          val result: Result<List<PdfTile>> = try {
            if (isTileStale(generation, tileEpoch)) throw cancelled(generation)
            val session = current ?: throw cancelled(generation)
            Result.success(session.renderTiles(requests) {
              if (isTileStale(generation, tileEpoch)) throw cancelled(generation)
            })
        } catch (error: Throwable) {
          Result.failure(error)
        }
        completion(result)
      }
    } catch (error: java.util.concurrent.RejectedExecutionException) {
      completion(Result.failure(cancelled(generation)))
    }
  }

  fun renderPreview(
    generation: Long,
    previewEpoch: Long,
    request: PdfTileRequest,
    completion: (Result<PdfTile>) -> Unit,
  ) {
    if (closed) {
      completion(Result.failure(cancelled(generation)))
      return
    }
    try {
      executor.execute {
        val result: Result<PdfTile> = try {
          if (isPreviewStale(generation, previewEpoch)) throw cancelled(generation)
          val session = current ?: throw cancelled(generation)
          val tile = session.renderPreview(request) {
            if (isPreviewStale(generation, previewEpoch)) throw cancelled(generation)
          }
          if (isPreviewStale(generation, previewEpoch)) {
            tile.bitmap.recycle()
            throw cancelled(generation)
          }
          Result.success(tile)
        } catch (error: Throwable) {
          Result.failure(error)
        }
        completion(result)
      }
    } catch (error: java.util.concurrent.RejectedExecutionException) {
      completion(Result.failure(cancelled(generation)))
    }
  }

  /** Replaces the latest viewport epoch for same-document tile work. */
  fun updateTileEpoch(generation: Long, tileEpoch: Long) {
    if (requestedGeneration == generation) requestedTileEpoch = tileEpoch
  }

  /** Replaces the independent epoch for presentation-only page previews. */
  fun updatePreviewEpoch(generation: Long, previewEpoch: Long) {
    if (requestedGeneration == generation) requestedPreviewEpoch = previewEpoch
  }

  /** Invalidates work for one generation without affecting a newer document. */
  fun cancel(generation: Long) {
    synchronized(stateLock) {
      if (requestedGeneration == generation) {
        requestedGeneration = Long.MIN_VALUE
        requestedTileEpoch = Long.MIN_VALUE
        requestedPreviewEpoch = Long.MIN_VALUE
      }
    }
  }

  fun export(
    snapshot: PdfExportSnapshot,
    artifactPolicy: CacheArtifactPolicy,
    completion: (Result<String>) -> Unit,
  ) {
    if (closed) {
      completion(Result.failure(cancelled(snapshot.generation)))
      return
    }
    try {
      executor.execute {
        val result: Result<String> = try {
          if (isStale(snapshot.generation)) throw cancelled(snapshot.generation)
          Result.success(PdfExporter.export(
            snapshot,
            artifactPolicy,
          ) { isStale(snapshot.generation) })
        } catch (error: Throwable) {
          Result.failure(error)
        }
        completion(result)
      }
    } catch (error: java.util.concurrent.RejectedExecutionException) {
      completion(Result.failure(cancelled(snapshot.generation)))
    }
  }

  private fun replaceOnWorker(
    path: String,
    generation: Long,
    fallbackFont: PdfFallbackFont?,
    completion: (Result<PdfSessionInfo>) -> Unit,
  ) {
    closeCurrent()
    if (isStale(generation)) {
      completion(Result.failure(cancelled(generation)))
      return
    }

    var candidate: PdfSessionResource? = null
    val result = try {
      val opened = opener.open(path, generation, fallbackFont)
      candidate = opened
      if (isStale(generation)) {
        opened.close()
        Result.failure(cancelled(generation))
      } else {
        current = opened
        Result.success(opened.info)
      }
    } catch (error: Exception) {
      candidate?.close()
      Result.failure<PdfSessionInfo>(error)
    }
    completion(result)
  }

  private fun mutateOnWorker(
    workingPath: String,
    candidatePath: String,
    generation: Long,
    request: PdfiumAssemblyRequest,
    fallbackFont: PdfFallbackFont?,
    retireCandidate: (File) -> Unit,
    completion: (Result<PdfSessionInfo>) -> Unit,
  ) {
    val candidateFile = File(candidatePath)
    val result = try {
      if (isStale(generation)) throw cancelled(generation)
      PdfiumPageAssembler.assemble(File(workingPath), request, candidateFile)
      if (isStale(generation)) throw cancelled(generation)
      val opened = opener.open(candidatePath, generation, fallbackFont)
      if (isStale(generation)) {
        opened.close()
        throw cancelled(generation)
      }
      val previous = current
      current = opened
      previous?.close()
      Result.success(opened.info)
    } catch (error: Throwable) {
      Result.failure<PdfSessionInfo>(error)
    }
    if (result.isFailure) retireCandidate(candidateFile)
    completion(result)
  }

  override fun close() {
    close(emptySet()) { }
  }

  /**
   * Invalidates all work, closes worker-owned readers, then retires the exact
   * final outputs registered by the view. The retirement runs behind queued
   * export work so an in-flight request cannot publish after disposal.
   */
  fun close(outputs: Collection<File>, retireOutput: (File) -> Unit) {
    synchronized(stateLock) {
      if (closed) return
      closed = true
      requestedGeneration = Long.MAX_VALUE
      requestedTileEpoch = Long.MAX_VALUE
      requestedPreviewEpoch = Long.MAX_VALUE
    }
    executor.execute {
      closeCurrent()
      outputs.forEach(retireOutput)
    }
    executor.shutdown()
  }

  private fun isStale(generation: Long): Boolean {
    return closed || requestedGeneration != generation
  }

  private fun isTileStale(generation: Long, tileEpoch: Long): Boolean {
    return isStale(generation) || requestedTileEpoch != tileEpoch
  }

  private fun isPreviewStale(generation: Long, previewEpoch: Long): Boolean {
    return isStale(generation) || requestedPreviewEpoch != previewEpoch
  }

  private fun closeCurrent() {
    val session = current
    current = null
    session?.close()
  }

  private fun cancelled(generation: Long): PdfSessionException {
    return PdfSessionException(
      "operation_cancelled",
      "PDF session generation $generation was superseded",
    )
  }
}

private object PdfWorkerThreadFactory : ThreadFactory {
  override fun newThread(runnable: Runnable): Thread {
    return Thread(runnable, "ReactNativeInkSignPdf.pdf").apply {
      isDaemon = true
    }
  }
}
