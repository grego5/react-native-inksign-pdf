package com.margelo.nitro.inksignpdf

import android.graphics.pdf.PdfRendererPreV
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.graphics.pdf.RenderParams
import android.graphics.pdf.models.selection.SelectionBoundary
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory

private const val compatibilityMapCandidateLimit = 256
private const val compatibilityMapRectangleLimit = 32
private const val compatibilityMapPageContentLimit = 256
private const val compatibilityMapLineLimit = 256
internal const val pdfCompatibilityPageCacheCapacity = 3

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

  /** Prepares shared geometry and the legacy fallback for an active page. */
  fun prepareCompatibility(request: PdfCompatibilityPageRequest): PdfCompatibilityPageResult

  /** Warms only shared geometry for a neighbor page; it never prepares fallback runs. */
  fun prepareSharedGeometry(request: PdfCompatibilityPageRequest): PdfCompatibilityPageResult

  /** Clears generation-local geometry and fallback data on the owning worker. */
  fun clearCompatibility() = Unit

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
}

internal data class PdfCompatibilityPageRequest(
  val generation: Long,
  val pageIndex: Int,
)

internal data class PdfCompatibilityPageResult(
  val request: PdfCompatibilityPageRequest,
  val sharedGeometry: PdfiumPageGeometry?,
  val fallbackRuns: List<PdfPreparedCompatibilityTextRun>,
  val sharedGeometryFailure: Boolean,
)

private class PdfCompatibilityPageData(
  val sharedGeometry: PdfiumPageGeometry?,
  val sharedGeometryFailure: Boolean,
) {
  var fallbackRuns: List<PdfPreparedCompatibilityTextRun>? = null
}

/**
 * The owned Android PDF document session. The renderer owns the descriptor
 * after construction; close still explicitly closes the descriptor after the
 * renderer so failed construction and all teardown paths are deterministic.
 */
internal class PdfSession private constructor(
  private val sourceDescriptor: ParcelFileDescriptor,
  private val immutableSource: File,
  private val renderer: PdfRendererPreV,
  override val info: PdfSessionInfo,
  private val pdfiumSession: PdfiumGeometrySession?,
) : PdfSessionResource {
  private val renderTransform = Matrix()
  private val renderParams = RenderParams.Builder(PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY).build()
  private val compatibilityDrawLogged = BooleanArray(info.pageCount)
  private val compatibilityPages = PdfPageLruCache<Int, PdfCompatibilityPageData>(
    pdfCompatibilityPageCacheCapacity,
  )
  private var closed = false

  override fun prepareCompatibility(
    request: PdfCompatibilityPageRequest,
  ): PdfCompatibilityPageResult {
    if (request.generation != info.generation || request.pageIndex !in 0 until info.pageCount) {
      return PdfCompatibilityPageResult(request, null, emptyList(), sharedGeometryFailure = true)
    }
    val data = compatibilityPages.getOrLoad(request.pageIndex) {
      loadSharedGeometry(request.pageIndex)
    }
    val fallbackRuns = data.fallbackRuns ?: loadFallbackRuns(request.pageIndex).also {
      data.fallbackRuns = it
    }
    return PdfCompatibilityPageResult(
      request = request,
      sharedGeometry = data.sharedGeometry,
      fallbackRuns = fallbackRuns,
      sharedGeometryFailure = data.sharedGeometryFailure,
    )
  }

  override fun prepareSharedGeometry(
    request: PdfCompatibilityPageRequest,
  ): PdfCompatibilityPageResult {
    if (request.generation != info.generation || request.pageIndex !in 0 until info.pageCount) {
      return PdfCompatibilityPageResult(request, null, emptyList(), sharedGeometryFailure = true)
    }
    val data = compatibilityPages.getOrLoad(request.pageIndex) {
      loadSharedGeometry(request.pageIndex)
    }
    return PdfCompatibilityPageResult(
      request = request,
      sharedGeometry = data.sharedGeometry,
      fallbackRuns = emptyList(),
      sharedGeometryFailure = data.sharedGeometryFailure,
    )
  }

  override fun clearCompatibility() {
    compatibilityPages.clear()
  }

  override fun close() {
    if (closed) return
    closed = true
    try {
      renderer.close()
    } finally {
      try {
        pdfiumSession?.close()
      } finally {
        compatibilityPages.clear()
        try {
          sourceDescriptor.close()
        } finally {
          immutableSource.delete()
        }
      }
    }
  }

  override fun renderTiles(
    requests: List<PdfTileRequest>,
    beforeEach: () -> Unit,
  ): List<PdfTile> {
    validatePdfTileBatch(info, requests)
    if (requests.isEmpty()) return emptyList()
    val pageIndex = requests.first().key.pageIndex
    val compatibility = prepareCompatibility(
      PdfCompatibilityPageRequest(info.generation, pageIndex),
    )
    val rendered = ArrayList<PdfTile>(requests.size)
    try {
      renderer.openPage(pageIndex).use { page ->
        requests.forEach { request ->
          beforeEach()
          val bitmap = Bitmap.createBitmap(
            request.widthPx,
            request.heightPx,
            Bitmap.Config.ARGB_8888,
          )
          try {
            renderTransform.setScale(request.scale.toFloat(), request.scale.toFloat())
            renderTransform.postTranslate(-request.leftPx.toFloat(), -request.topPx.toFloat())
            page.render(bitmap, null, renderTransform, renderParams)
            val logCompatibilityDraw = BuildConfig.DEBUG && !compatibilityDrawLogged[pageIndex]
            val beforeOverlayPixels = if (logCompatibilityDraw) {
              IntArray(bitmap.width * bitmap.height).also { pixels ->
                bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
              }
            } else {
              null
            }
            PdfCompatibilityTextRenderer.draw(
              canvas = android.graphics.Canvas(bitmap),
              request = request,
              runs = compatibility.fallbackRuns,
            )
            if (logCompatibilityDraw) {
              compatibilityDrawLogged[pageIndex] = true
              val changedPixels = beforeOverlayPixels?.let { before ->
                val after = IntArray(before.size)
                bitmap.getPixels(after, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                after.indices.count { index -> after[index] != before[index] }
              } ?: 0
              val runSummary = compatibility.fallbackRuns
                .take(4)
                .joinToString(separator = ";") { it.debugSummary() }
              Log.d(
                "InkSignPdf",
                "Compatibility text first draw: page=$pageIndex " +
                  "runs=${compatibility.fallbackRuns.size} " +
                  "tile=${request.leftPx},${request.topPx},${request.widthPx}x${request.heightPx} " +
                  "scale=${request.scale} changedPixels=$changedPixels " +
                  "clip=0,0,${bitmap.width},${bitmap.height} runSummary=$runSummary",
              )
            }
            rendered += PdfTile(request, bitmap)
          } catch (error: Throwable) {
            bitmap.recycle()
            throw error
          }
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

  private fun loadSharedGeometry(pageIndex: Int): PdfCompatibilityPageData {
    var sharedGeometry: PdfiumPageGeometry? = null
    var sharedGeometryFailure = false
    if (pdfiumSession != null) {
      try {
        sharedGeometry = pdfiumSession.extractPage(pageIndex)
      } catch (error: Throwable) {
        sharedGeometryFailure = true
        if (BuildConfig.DEBUG) {
          Log.d(
            "InkSignPdf",
            "Shared PDFium geometry unavailable: page=$pageIndex " +
              "code=${(error as? PdfSessionException)?.code ?: "native_error"}",
          )
        }
      }
    } else {
      sharedGeometryFailure = true
    }

    return PdfCompatibilityPageData(sharedGeometry, sharedGeometryFailure)
  }

  private fun loadFallbackRuns(pageIndex: Int): List<PdfPreparedCompatibilityTextRun> {
    return try {
      extractCompatibilityRuns(pageIndex)
    } catch (error: Throwable) {
      if (BuildConfig.DEBUG) {
        Log.d(
          "InkSignPdf",
          "Heuristic compatibility extraction failed: page=$pageIndex " +
            "code=${(error as? PdfSessionException)?.code ?: "renderer_error"}",
        )
      }
      emptyList()
    }
  }

  private fun extractCompatibilityRuns(pageIndex: Int): List<PdfPreparedCompatibilityTextRun> {
    return renderer.openPage(pageIndex).use { page ->
      val dimensions = PdfPageDimensions(page.width.toDouble(), page.height.toDouble())
      if (dimensions.width <= 0.0 || dimensions.height <= 0.0) return@use emptyList()
      val textContents = page.getTextContents()
      val textStream = textContents.joinToString(separator = "") { it.text }
      val lineGeometry = collectCompatibilityTextLines(page, textContents, textStream)
      val selection = resolveCompatibilitySelection(
        page = page,
        textStream = textStream,
        pageIndex = pageIndex,
        dimensions = dimensions,
        lines = lineGeometry.lines,
      )
      val extraction = PdfCompatibilityTextExtractor.extract(
        candidateCount = selection.candidateCount,
        spans = selection.spans,
        initialRejectedGeometryCount = selection.rejectedGeometryCount,
        collectDiagnostics = BuildConfig.DEBUG,
      )
      if (BuildConfig.DEBUG) {
        extraction.diagnostics
          .filter { it.candidateIndex in 0 until compatibilityMapCandidateLimit }
          .forEach { diagnostic ->
            PdfCompatibilityMapLogger.log(
              "page=$pageIndex candidate=${diagnostic.candidateIndex} " +
                "stage=disposition disposition=${diagnostic.disposition.name.lowercase()} " +
                "fragmentCount=${diagnostic.geometry?.fragmentCount ?: 0} " +
                "clusterCount=${diagnostic.geometry?.clusters?.size ?: 0}",
            )
          }
        if (selection.candidateCount > compatibilityMapCandidateLimit) {
          PdfCompatibilityMapLogger.log(
            "page=$pageIndex stage=candidateTruncation " +
              "emitted=$compatibilityMapCandidateLimit " +
              "omitted=${selection.candidateCount - compatibilityMapCandidateLimit}",
          )
        }
        Log.d(
          "InkSignPdf",
          "Compatibility text extraction: page=$pageIndex " +
            "candidates=${extraction.candidateCount} " +
            "acceptedGroupedRuns=${extraction.acceptedGroupedRunCount} " +
            "rejectedGeometry=${extraction.rejectedGeometryCount} " +
            "preparationRejections=${extraction.preparationRejectionCount} " +
            "selection=${selection.spans.size}",
        )
      }
      extraction.runs
    }
  }

  companion object : PdfSessionOpener {
    override fun open(path: String, generation: Long): PdfSessionResource {
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

      val immutableSource = try {
        val snapshot = File.createTempFile("inksign-pdf-session-", ".pdf")
        try {
          snapshot.outputStream().use { output -> output.write(sourceBytes) }
          snapshot
        } catch (error: Throwable) {
          snapshot.delete()
          throw error
        }
      } catch (error: IOException) {
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to create an immutable PDF snapshot",
          error,
        )
      } catch (error: SecurityException) {
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to create an immutable PDF snapshot",
          error,
        )
      }

      val descriptor = try {
        ParcelFileDescriptor.open(immutableSource, ParcelFileDescriptor.MODE_READ_ONLY)
      } catch (error: SecurityException) {
        immutableSource.delete()
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to read the PDF",
          error,
        )
      } catch (error: IOException) {
        immutableSource.delete()
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to open the PDF",
          error,
        )
      }

      var renderer: PdfRendererPreV? = null
      var pdfiumSession: PdfiumGeometrySession? = null
      try {
        val openedRenderer = PdfRendererPreV(descriptor)
        renderer = openedRenderer
        if (openedRenderer.pageCount <= 0) {
          throw PdfSessionException(
            "pdf_load_failed",
            "The PDF has no pages",
          )
        }

        val pages = ArrayList<PdfPageDimensions>(openedRenderer.pageCount)
        (0 until openedRenderer.pageCount).forEach { pageIndex ->
          openedRenderer.openPage(pageIndex).use { page ->
            val width = page.width.toDouble()
            val height = page.height.toDouble()
            if (width <= 0.0 || height <= 0.0) {
              throw PdfSessionException(
                "pdf_load_failed",
                "The PDF page has invalid dimensions",
              )
            }
            val dimensions = PdfPageDimensions(width, height)
            pages += dimensions
          }
        }
        pdfiumSession = try {
          val nativeSession = PdfiumGeometrySession.open(sourceBytes)
          if (nativeSession.pageCount != openedRenderer.pageCount) {
            nativeSession.close()
            null
          } else {
            nativeSession
          }
        } catch (error: Throwable) {
          if (BuildConfig.DEBUG) {
            Log.d(
              "InkSignPdf",
              "Shared PDFium session unavailable during open: " +
                "code=${(error as? PdfSessionException)?.code ?: "native_error"}",
            )
          }
          null
        }
        return PdfSession(
          sourceDescriptor = descriptor,
          immutableSource = immutableSource,
          renderer = openedRenderer,
          info = PdfSessionInfo(source.path, pages, generation),
          pdfiumSession = pdfiumSession,
        )
      } catch (error: PdfSessionException) {
        pdfiumSession?.close()
        closeFailedPdfResources(renderer, descriptor, immutableSource)
        throw error
      } catch (error: SecurityException) {
        pdfiumSession?.close()
        closeFailedPdfResources(renderer, descriptor, immutableSource)
        throw PdfSessionException(
          "unsupported_pdf",
          "The PDF is protected or uses an unsupported security scheme",
          error,
        )
      } catch (error: Exception) {
        pdfiumSession?.close()
        closeFailedPdfResources(renderer, descriptor, immutableSource)
        throw PdfSessionException(
          "pdf_load_failed",
          "Unable to load the PDF",
          error,
        )
      }
    }

  }
}

private data class PdfCompatibilitySelection(
  val candidateCount: Int,
  val spans: List<PdfCompatibilityTextSpan>,
  val rejectedGeometryCount: Int,
  val newlineOrControlTerminations: Int = 0,
  val unrelatedTextTerminations: Int = 0,
  val trailingBridgeTerminations: Int = 0,
)

private data class PdfCompatibilityLineGeometry(
  val source: PdfCompatibilityTextLineSource?,
  val lines: List<PdfCompatibilityTextLine>,
)

private fun collectCompatibilityTextLines(
  page: PdfRendererPreV.Page,
  textContents: List<android.graphics.pdf.content.PdfPageTextContent>,
  textStream: String,
): PdfCompatibilityLineGeometry {
  val contentLines = ArrayList<PdfCompatibilityTextLine>()
  textContents.forEach { content ->
    content.bounds.forEach { bounds ->
      val copiedBounds = android.graphics.RectF(bounds)
      if (isUsableCompatibilityLineBounds(copiedBounds)) {
        contentLines += PdfCompatibilityTextLine(
          source = PdfCompatibilityTextLineSource.TEXT_CONTENTS,
          index = contentLines.size,
          bounds = copiedBounds,
        )
      }
    }
  }
  if (contentLines.isNotEmpty()) {
    return PdfCompatibilityLineGeometry(
      source = PdfCompatibilityTextLineSource.TEXT_CONTENTS,
      lines = contentLines.toList(),
    )
  }
  if (textStream.isEmpty()) {
    return PdfCompatibilityLineGeometry(source = null, lines = emptyList())
  }
  val wholePageContents = try {
    page.selectContent(
      SelectionBoundary(0),
      SelectionBoundary(textStream.length),
    )?.selectedTextContents.orEmpty()
  } catch (_: RuntimeException) {
    emptyList()
  }
  val selectedLines = ArrayList<PdfCompatibilityTextLine>()
  wholePageContents.forEach { content ->
    content.bounds.forEach { bounds ->
      val copiedBounds = android.graphics.RectF(bounds)
      if (isUsableCompatibilityLineBounds(copiedBounds)) {
        selectedLines += PdfCompatibilityTextLine(
          source = PdfCompatibilityTextLineSource.WHOLE_PAGE_SELECTION,
          index = selectedLines.size,
          bounds = copiedBounds,
        )
      }
    }
  }
  return PdfCompatibilityLineGeometry(
    source = if (selectedLines.isEmpty()) null else
      PdfCompatibilityTextLineSource.WHOLE_PAGE_SELECTION,
    lines = selectedLines.toList(),
  )
}

private fun resolveCompatibilitySelection(
  page: PdfRendererPreV.Page,
  textStream: String,
  pageIndex: Int,
  dimensions: PdfPageDimensions,
  lines: List<PdfCompatibilityTextLine>,
): PdfCompatibilitySelection {
  if (textStream.isEmpty()) {
    return PdfCompatibilitySelection(0, emptyList(), 0)
  }

  val groupingDiagnostics = if (BuildConfig.DEBUG) {
    PdfCompatibilityTextGroupingDiagnostics()
  } else {
    null
  }
  val candidates = groupCompatibilityTextCandidates(
    text = textStream,
    diagnostics = groupingDiagnostics,
  )
  val spans = ArrayList<PdfCompatibilityTextSpan>()
  var rejectedGeometryCount = 0
  candidates.forEachIndexed candidateLoop@ { candidateIndex, candidate ->
    val shouldLogCandidate = BuildConfig.DEBUG &&
      candidateIndex < compatibilityMapCandidateLimit
    if (shouldLogCandidate) {
      PdfCompatibilityMapLogger.log(
        "page=$pageIndex candidate=$candidateIndex stage=candidate " +
          "pageWidth=${dimensions.width} pageHeight=${dimensions.height} " +
          "utf16Range=${candidate.start}-${candidate.end} " +
          "codePoints=${formatCompatibilityCodePoints(candidate.text)} " +
          "characterCount=${decodePdfScalars(candidate.text)?.size ?: -1} " +
          "utf16Length=${candidate.text.length}",
      )
    }
    var selectionFailed = false
    val pageSelection = try {
      page.selectContent(
        SelectionBoundary(candidate.start),
        SelectionBoundary(candidate.end),
      )
    } catch (_: RuntimeException) {
      selectionFailed = true
      null
    }
    val selectedContents = pageSelection?.selectedTextContents.orEmpty()
    val selectionStartX = pageSelection?.start?.point?.x?.toFloat()
    val selectionStopX = pageSelection?.stop?.point?.x?.toFloat()
    val selectedText = buildString {
      selectedContents.forEach { append(it.text) }
    }
    if (shouldLogCandidate) {
      PdfCompatibilityMapLogger.log(
        "page=$pageIndex candidate=$candidateIndex stage=selection " +
          "selectionFailed=$selectionFailed selectedEntries=${selectedContents.size} " +
            "exactTextMatch=${selectedText == candidate.text} " +
            "boundaryStartX=${selectionStartX ?: "none"} " +
            "boundaryStopX=${selectionStopX ?: "none"} " +
            "codePoints=${formatCompatibilityCodePoints(selectedText)} " +
          "characterCount=${decodePdfScalars(selectedText)?.size ?: -1} " +
          "utf16Length=${selectedText.length}",
      )
      var loggedRectangles = 0
      selectedContents.forEachIndexed { contentIndex, content ->
        val available = (compatibilityMapRectangleLimit - loggedRectangles).coerceAtLeast(0)
        val rectangles = content.bounds
          .take(available)
          .mapIndexed { localIndex, bounds ->
            val rectangleIndex = loggedRectangles + localIndex
            "$rectangleIndex:${formatCompatibilityRect(android.graphics.RectF(bounds))}"
          }
        loggedRectangles += rectangles.size
        PdfCompatibilityMapLogger.log(
          "page=$pageIndex candidate=$candidateIndex stage=selectionContent " +
            "index=$contentIndex codePoints=${formatCompatibilityCodePoints(content.text)} " +
            "characterCount=${decodePdfScalars(content.text)?.size ?: -1} " +
            "utf16Length=${content.text.length} rectCount=${content.bounds.size} " +
            "rectangles=$rectangles",
        )
      }
      val omittedRectangles = selectedContents.sumOf { it.bounds.size } - loggedRectangles
      if (omittedRectangles > 0) {
        PdfCompatibilityMapLogger.log(
          "page=$pageIndex candidate=$candidateIndex stage=selectionRectangleTruncation " +
            "emitted=$loggedRectangles omitted=$omittedRectangles",
        )
      }
    }
    if (selectedContents.isEmpty()) {
      rejectedGeometryCount += 1
      if (shouldLogCandidate) {
        PdfCompatibilityMapLogger.log(
          "page=$pageIndex candidate=$candidateIndex stage=disposition " +
            "disposition=unusable_geometry reason=selection_empty",
        )
      }
      return@candidateLoop
    }
    val selectedBounds = selectedContents.flatMap { content ->
      content.bounds.map { android.graphics.RectF(it) }
    }
    if (selectedText.isNotEmpty() && selectedBounds.isNotEmpty()) {
      spans += PdfCompatibilityTextSpan(
        text = selectedText,
        bounds = selectedBounds,
        candidateIndex = candidateIndex,
        lineMatches = selectedBounds.map { bounds ->
          matchCompatibilityTextLine(bounds, lines)
        },
        utf16Start = candidate.start,
        utf16End = candidate.end,
        selectionStartX = selectionStartX,
        selectionStopX = selectionStopX,
      )
    } else {
      rejectedGeometryCount += 1
      if (shouldLogCandidate) {
        PdfCompatibilityMapLogger.log(
          "page=$pageIndex candidate=$candidateIndex stage=disposition " +
            "disposition=unusable_geometry reason=empty_selected_text_or_rectangles",
        )
      }
    }
  }
  return PdfCompatibilitySelection(
    candidateCount = candidates.size,
    spans = spans.toList(),
    rejectedGeometryCount = rejectedGeometryCount,
    newlineOrControlTerminations = groupingDiagnostics?.newlineOrControlTerminations ?: 0,
    unrelatedTextTerminations = groupingDiagnostics?.unrelatedTextTerminations ?: 0,
    trailingBridgeTerminations = groupingDiagnostics?.trailingBridgeTerminations ?: 0,
  )
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
            replaceOnWorker(path, generation, completion)
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
            val pageIndex = requests.firstOrNull()?.key?.pageIndex
            if (pageIndex != null) {
              prepareCompatibilityOnWorker(session, generation, pageIndex)
            }
            Result.success(session.renderTiles(requests) {
              if (isTileStale(generation, tileEpoch)) throw cancelled(generation)
            }).also {
              if (pageIndex != null) {
                enqueueCompatibilityPrefetch(session, generation, pageIndex)
              }
            }
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
          prepareCompatibilityOnWorker(session, generation, request.key.pageIndex)
          val tile = session.renderPreview(request) {
            if (isPreviewStale(generation, previewEpoch)) throw cancelled(generation)
          }
          if (isPreviewStale(generation, previewEpoch)) {
            tile.bitmap.recycle()
            throw cancelled(generation)
          }
          enqueueCompatibilityPrefetch(session, generation, request.key.pageIndex)
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
    try {
      executor.execute {
        if (current?.info?.generation == generation) current?.clearCompatibility()
      }
    } catch (_: java.util.concurrent.RejectedExecutionException) {
      // Disposal already owns teardown; no cache survives the worker.
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
    completion: (Result<PdfSessionInfo>) -> Unit,
  ) {
    closeCurrent()
    if (isStale(generation)) {
      completion(Result.failure(cancelled(generation)))
      return
    }

    var candidate: PdfSessionResource? = null
    val result = try {
      val opened = opener.open(path, generation)
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

  private fun prepareCompatibilityOnWorker(
    session: PdfSessionResource,
    generation: Long,
    pageIndex: Int,
  ) {
    if (isStale(generation)) throw cancelled(generation)
    val request = PdfCompatibilityPageRequest(generation, pageIndex)
    val result = session.prepareCompatibility(request)
    if (result.request != request || isStale(generation)) throw cancelled(generation)
  }

  private fun prepareSharedGeometryOnWorker(
    session: PdfSessionResource,
    generation: Long,
    pageIndex: Int,
  ) {
    if (isStale(generation)) throw cancelled(generation)
    val request = PdfCompatibilityPageRequest(generation, pageIndex)
    val result = session.prepareSharedGeometry(request)
    if (result.request != request || isStale(generation)) throw cancelled(generation)
  }

  private fun enqueueCompatibilityPrefetch(
    session: PdfSessionResource,
    generation: Long,
    activePageIndex: Int,
  ) {
    val neighbors = listOf(activePageIndex - 1, activePageIndex + 1)
      .filter { it in 0 until session.info.pageCount }
    if (neighbors.isEmpty()) return
    try {
      executor.execute {
        if (isStale(generation) || current !== session) return@execute
        neighbors.forEach { pageIndex ->
          if (!isStale(generation)) {
            prepareSharedGeometryOnWorker(session, generation, pageIndex)
          }
        }
      }
    } catch (_: java.util.concurrent.RejectedExecutionException) {
      // Disposal invalidates the generation and clears the current resource.
    }
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
