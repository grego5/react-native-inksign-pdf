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
}

/**
 * The owned Android PDF document session. The renderer owns the descriptor
 * after construction; close still explicitly closes the descriptor after the
 * renderer so failed construction and all teardown paths are deterministic.
 */
internal class PdfSession private constructor(
  private val sourceDescriptor: ParcelFileDescriptor,
  private val renderer: PdfRendererPreV,
  override val info: PdfSessionInfo,
  private val compatibilityTextRuns: List<List<PdfPreparedCompatibilityTextRun>>,
) : PdfSessionResource {
  private val renderTransform = Matrix()
  private val renderParams = RenderParams.Builder(PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY).build()
  private val compatibilityDrawLogged = BooleanArray(info.pageCount)
  private var closed = false

  override fun close() {
    if (closed) return
    closed = true
    try {
      renderer.close()
    } finally {
      sourceDescriptor.close()
    }
  }

  override fun renderTiles(
    requests: List<PdfTileRequest>,
    beforeEach: () -> Unit,
  ): List<PdfTile> {
    validatePdfTileBatch(info, requests)
    if (requests.isEmpty()) return emptyList()
    val pageIndex = requests.first().key.pageIndex
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
              runs = compatibilityTextRuns[pageIndex],
            )
            if (logCompatibilityDraw) {
              compatibilityDrawLogged[pageIndex] = true
              val changedPixels = beforeOverlayPixels?.let { before ->
                val after = IntArray(before.size)
                bitmap.getPixels(after, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                after.indices.count { index -> after[index] != before[index] }
              } ?: 0
              val runSummary = compatibilityTextRuns[pageIndex]
                .take(4)
                .joinToString(separator = ";") { it.debugSummary() }
              Log.d(
                "InkSignPdf",
                "Compatibility text first draw: page=$pageIndex " +
                  "runs=${compatibilityTextRuns[pageIndex].size} " +
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

      val descriptor = try {
        ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
      } catch (error: SecurityException) {
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to read the PDF",
          error,
        )
      } catch (error: IOException) {
        throw PdfSessionException(
          "invalid_source_path",
          "Unable to open the PDF",
          error,
        )
      }

      var renderer: PdfRendererPreV? = null
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
        val compatibilityRuns = ArrayList<List<PdfPreparedCompatibilityTextRun>>(openedRenderer.pageCount)
        var mapTotalCandidates = 0
        var mapTotalAccepted = 0
        var mapTotalRejectedGeometry = 0
        var mapTotalSingleRectangle = 0
        var mapTotalMergedSameLine = 0
        var mapTotalMergedFragments = 0
        var mapTotalAmbiguousMultiline = 0
        var mapTotalUnusableGeometry = 0
        var mapTotalPreparationFailures = 0
        var mapTotalScaleRejections = 0
        var mapTotalMatchedLines = 0
        var mapTotalStandaloneFallbacks = 0
        var mapTotalUnmatchedCandidates = 0
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
            val textContents = page.getTextContents()
            val textStream = textContents.joinToString(separator = "") { it.text }
            val lineGeometry = collectCompatibilityTextLines(page, textContents, textStream)
            if (BuildConfig.DEBUG) {
              PdfCompatibilityMapLogger.log(
                "page=$pageIndex stage=page width=$width height=$height " +
                  "textContents=${textContents.size}",
              )
              textContents.take(compatibilityMapPageContentLimit).forEachIndexed { contentIndex, content ->
                PdfCompatibilityMapLogger.log(
                  "page=$pageIndex stage=pageContentHeader index=$contentIndex " +
                    "codePointSummary=${formatCompatibilityCodePointSummary(content.text)} " +
                    "characterCount=${decodePdfScalars(content.text)?.size ?: -1} " +
                    "utf16Length=${content.text.length} lineRectangles=${content.bounds.size}",
                )
              }
              if (textContents.size > compatibilityMapPageContentLimit) {
                PdfCompatibilityMapLogger.log(
                  "page=$pageIndex stage=pageContentTruncation " +
                    "emitted=$compatibilityMapPageContentLimit " +
                  "omitted=${textContents.size - compatibilityMapPageContentLimit}",
                )
              }
              lineGeometry.lines.take(compatibilityMapLineLimit).forEach { line ->
                PdfCompatibilityMapLogger.log(
                  "page=$pageIndex stage=pageLine source=${line.source.name.lowercase()} " +
                    "index=${line.index} rect=${formatCompatibilityRect(line.bounds)}",
                )
              }
              if (lineGeometry.lines.size > compatibilityMapLineLimit) {
                PdfCompatibilityMapLogger.log(
                  "page=$pageIndex stage=pageLineTruncation " +
                    "emitted=$compatibilityMapLineLimit " +
                    "omitted=${lineGeometry.lines.size - compatibilityMapLineLimit}",
                )
              }
              PdfCompatibilityMapLogger.log(
                "page=$pageIndex stage=pageLineSource " +
                  "source=${lineGeometry.source?.name?.lowercase() ?: "none"} " +
                  "count=${lineGeometry.lines.size}",
              )
            }
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
            )
            compatibilityRuns += extraction.runs
            mapTotalCandidates += extraction.candidateCount
            mapTotalAccepted += extraction.acceptedGroupedRunCount
            mapTotalRejectedGeometry += extraction.rejectedGeometryCount
            mapTotalSingleRectangle += extraction.singleRectangleSpanCount
            mapTotalMergedSameLine += extraction.mergedSameLineSpanCount
            mapTotalMergedFragments += extraction.mergedFragmentCount
            mapTotalAmbiguousMultiline += extraction.rejectedMultiLineMappingCount
            mapTotalUnusableGeometry += extraction.rejectedUnusableGeometryCount
            mapTotalPreparationFailures += extraction.preparationRejectionCount
            mapTotalScaleRejections += extraction.scaleRejectionCount
            mapTotalMatchedLines += extraction.matchedLineCount
            mapTotalStandaloneFallbacks += extraction.standaloneFallbackCount
            mapTotalUnmatchedCandidates += extraction.unmatchedCandidateCount
            if (BuildConfig.DEBUG) {
              extraction.diagnostics
                .filter { it.candidateIndex in 0 until compatibilityMapCandidateLimit }
                .forEach { diagnostic ->
                  val geometry = diagnostic.geometry
                  diagnostic.rectangles.forEach { rectangle ->
                    val matchedLine = rectangle.matchedLine
                    PdfCompatibilityMapLogger.log(
                      "page=$pageIndex candidate=${diagnostic.candidateIndex} " +
                        "stage=geometry rectangle=${rectangle.index} " +
                        "selection=${formatCompatibilityRect(rectangle.selectionBounds)} " +
                        "matchedLineSource=${matchedLine?.source?.name?.lowercase() ?: "none"} " +
                        "matchedLineIndex=${matchedLine?.index ?: -1} " +
                        "matchedLine=${matchedLine?.let { formatCompatibilityRect(it.bounds) } ?: "none"} " +
                        "standaloneFallback=${rectangle.standaloneFallback} " +
                        "final=${rectangle.finalBounds?.let { formatCompatibilityRect(it) } ?: "none"}",
                    )
                  }
                  if (geometry != null) {
                    geometry.clusters.forEachIndexed { clusterIndex, cluster ->
                      PdfCompatibilityMapLogger.log(
                        "page=$pageIndex candidate=${diagnostic.candidateIndex} " +
                          "stage=cluster index=$clusterIndex members=${cluster.memberIndexes} " +
                          "union=${formatCompatibilityRect(cluster.bounds)}",
                      )
                    }
                  }
                  diagnostic.preparations.forEachIndexed { partIndex, preparation ->
                    PdfCompatibilityMapLogger.log(
                      "page=$pageIndex candidate=${diagnostic.candidateIndex} " +
                        "stage=preparation part=$partIndex " +
                        "measuredWidth=${preparation.measuredWidth} " +
                        "sourceWidth=${preparation.sourceWidth} " +
                        "sourceHeight=${preparation.sourceHeight} " +
                        "fontSize=${preparation.fontSize} " +
                        "horizontalScale=${preparation.horizontalScale} " +
                        "baseline=${preparation.baseline} " +
                        "layout=${preparation.layoutWidth}x${preparation.layoutHeight} " +
                        "rejection=${preparation.rejection}",
                    )
                  }
                  PdfCompatibilityMapLogger.log(
                    "page=$pageIndex candidate=${diagnostic.candidateIndex} " +
                      "stage=disposition disposition=${diagnostic.disposition.name.lowercase()} " +
                      "fragmentCount=${geometry?.fragmentCount ?: 0} " +
                      "clusterCount=${geometry?.clusters?.size ?: 0}",
                  )
                }
              if (selection.candidateCount > compatibilityMapCandidateLimit) {
                PdfCompatibilityMapLogger.log(
                  "page=$pageIndex stage=candidateTruncation " +
                    "emitted=$compatibilityMapCandidateLimit " +
                    "omitted=${selection.candidateCount - compatibilityMapCandidateLimit}",
                )
              }
              val selectionSummary = if (textStream.isNotEmpty()) {
                "candidateSpans=${selection.candidateCount},selectedSpans=${selection.spans.size}"
              } else {
                "not_attempted"
              }
              Log.d(
                "InkSignPdf",
                "Compatibility text extraction: page=$pageIndex " +
                  "candidates=${extraction.candidateCount} " +
                  "acceptedGroupedRuns=${extraction.acceptedGroupedRunCount} " +
                  "rejectedGeometry=${extraction.rejectedGeometryCount} " +
                  "singleRectangleSpans=${extraction.singleRectangleSpanCount} " +
                  "mergedSameLineSpans=${extraction.mergedSameLineSpanCount} " +
                  "mergedFragments=${extraction.mergedFragmentCount} " +
                  "rejectedMultiLineMappings=${extraction.rejectedMultiLineMappingCount} " +
                  "unusableGeometryRejections=${extraction.rejectedUnusableGeometryCount} " +
                  "preparationRejections=${extraction.preparationRejectionCount} " +
                  "scaleRejections=${extraction.scaleRejectionCount} " +
                  "textContents=${textContents.size} " +
                  "selection=$selectionSummary",
              )
              PdfCompatibilityMapLogger.log(
                "page=$pageIndex stage=totals candidates=${extraction.candidateCount} " +
                  "accepted=${extraction.acceptedGroupedRunCount} " +
                  "rejectedGeometry=${extraction.rejectedGeometryCount} " +
                  "singleRectangle=${extraction.singleRectangleSpanCount} " +
                  "mergedSameLine=${extraction.mergedSameLineSpanCount} " +
                  "mergedFragments=${extraction.mergedFragmentCount} " +
                  "ambiguousMultiline=${extraction.rejectedMultiLineMappingCount} " +
                  "unusableGeometry=${extraction.rejectedUnusableGeometryCount} " +
                      "preparationFailures=${extraction.preparationRejectionCount} " +
                  "scaleRejections=${extraction.scaleRejectionCount} " +
                  "matchedLines=${extraction.matchedLineCount} " +
                  "standaloneFallbacks=${extraction.standaloneFallbackCount} " +
                  "unmatchedCandidates=${extraction.unmatchedCandidateCount}",
              )
            }
          }
        }
        if (BuildConfig.DEBUG) {
          PdfCompatibilityMapLogger.log(
            "page=all stage=totals pages=${openedRenderer.pageCount} " +
              "candidates=$mapTotalCandidates accepted=$mapTotalAccepted " +
              "rejectedGeometry=$mapTotalRejectedGeometry " +
              "singleRectangle=$mapTotalSingleRectangle " +
              "mergedSameLine=$mapTotalMergedSameLine " +
              "mergedFragments=$mapTotalMergedFragments " +
              "ambiguousMultiline=$mapTotalAmbiguousMultiline " +
              "unusableGeometry=$mapTotalUnusableGeometry " +
              "preparationFailures=$mapTotalPreparationFailures " +
              "scaleRejections=$mapTotalScaleRejections " +
              "matchedLines=$mapTotalMatchedLines " +
              "standaloneFallbacks=$mapTotalStandaloneFallbacks " +
              "unmatchedCandidates=$mapTotalUnmatchedCandidates",
          )
        }
        return PdfSession(
          sourceDescriptor = descriptor,
          renderer = openedRenderer,
          info = PdfSessionInfo(source.path, pages, generation),
          compatibilityTextRuns = compatibilityRuns.toList(),
        )
      } catch (error: PdfSessionException) {
        closeFailedPdfResources(renderer, descriptor)
        throw error
      } catch (error: SecurityException) {
        closeFailedPdfResources(renderer, descriptor)
        throw PdfSessionException(
          "unsupported_pdf",
          "The PDF is protected or uses an unsupported security scheme",
          error,
        )
      } catch (error: Exception) {
        closeFailedPdfResources(renderer, descriptor)
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

  val candidates = groupCompatibilityTextCandidates(textStream)
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
    val selectedContents = try {
      page.selectContent(
        SelectionBoundary(candidate.start),
        SelectionBoundary(candidate.end),
      )?.selectedTextContents.orEmpty()
    } catch (_: RuntimeException) {
      selectionFailed = true
      emptyList()
    }
    val selectedText = buildString {
      selectedContents.forEach { append(it.text) }
    }
    if (shouldLogCandidate) {
      PdfCompatibilityMapLogger.log(
        "page=$pageIndex candidate=$candidateIndex stage=selection " +
          "selectionFailed=$selectionFailed selectedEntries=${selectedContents.size} " +
          "exactTextMatch=${selectedText == candidate.text} " +
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
  return PdfCompatibilitySelection(candidates.size, spans.toList(), rejectedGeometryCount)
}

/** Closes a partially opened PDF without closing a descriptor twice. */
internal fun closeFailedPdfResources(
  renderer: PdfRendererPreV?,
  descriptor: ParcelFileDescriptor,
) {
  if (renderer != null) renderer.close() else descriptor.close()
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
