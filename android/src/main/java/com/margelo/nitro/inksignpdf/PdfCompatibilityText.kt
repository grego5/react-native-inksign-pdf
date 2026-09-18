package com.margelo.nitro.inksignpdf

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.RectF
import android.graphics.Typeface
import android.text.SpannableString
import android.text.StaticLayout
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.util.Log
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

private val compatibilityTypeface = Typeface.DEFAULT
private const val minimumCompatibilityHorizontalScale = 0.5f
private const val maximumCompatibilityHorizontalScale = 2.0f

internal enum class PdfCompatibilityTextLineSource {
  TEXT_CONTENTS,
  WHOLE_PAGE_SELECTION,
}

internal data class PdfCompatibilityTextLine(
  val source: PdfCompatibilityTextLineSource,
  val index: Int,
  val bounds: RectF,
)

/** A copied logical text span selected from one worker-owned PDF page. */
internal data class PdfCompatibilityTextSpan(
  val text: String,
  val bounds: List<RectF>,
  val candidateIndex: Int = -1,
  val lineMatches: List<PdfCompatibilityTextLine?> = emptyList(),
) {
  init {
    require(text.isNotEmpty())
    require(bounds.isNotEmpty())
  }
}

/** The affine transform from page coordinates to the prepared layout. */
internal data class CanvasTextMatrix(
  val a: Float,
  val b: Float,
  val c: Float,
  val d: Float,
  val tx: Float,
  val ty: Float,
) {
  private val androidMatrix = Matrix().apply {
    setValues(floatArrayOf(
      a, c, tx,
      b, d, ty,
      0f, 0f, 1f,
    ))
  }

  fun toAndroidMatrix(): Matrix {
    return androidMatrix
  }
}

internal data class PdfCompatibilityTextRun(
  val text: String,
  val bounds: RectF,
) {
  fun prepare(): PdfPreparedCompatibilityTextRun? {
    return prepareWithDiagnostics().run
  }

  internal fun prepareWithDiagnostics(): PdfCompatibilityTextPreparationResult {
    val sourceLeft = bounds.left
    val sourceTop = bounds.top
    val sourceBottom = bounds.bottom
    val sourceAdvance = bounds.width()
    val sourceHeight = bounds.height()
    val probePaint = TextLayoutSpec.createPaint(1.0, typeface = compatibilityTypeface)
    val probeMetrics = probePaint.fontMetrics
    val probeMetricHeight = probeMetrics.descent - probeMetrics.ascent
    if (!sourceHeight.isFinite() || sourceHeight <= 0f ||
      !probeMetricHeight.isFinite() || probeMetricHeight <= 0f
    ) return PdfCompatibilityTextPreparationResult(
      run = null,
      rejection = PdfCompatibilityTextPreparationRejection.PREPARATION,
      sourceWidth = sourceAdvance,
      sourceHeight = sourceHeight,
    )

    val fontSize = sourceHeight / probeMetricHeight
    if (!fontSize.isFinite() || fontSize <= 0f) {
      return PdfCompatibilityTextPreparationResult(
        run = null,
        rejection = PdfCompatibilityTextPreparationRejection.PREPARATION,
        sourceWidth = sourceAdvance,
        sourceHeight = sourceHeight,
        fontSize = fontSize,
      )
    }
    val paint = TextLayoutSpec.createPaint(fontSize.toDouble(), typeface = compatibilityTypeface)
    val measuredWidth = paint.measureText(text)
    if (!measuredWidth.isFinite() || measuredWidth <= 0f) {
      return PdfCompatibilityTextPreparationResult(
        run = null,
        rejection = PdfCompatibilityTextPreparationRejection.PREPARATION,
        sourceWidth = sourceAdvance,
        sourceHeight = sourceHeight,
        fontSize = fontSize,
        measuredWidth = measuredWidth,
      )
    }
    val layoutWidth = max(1, ceil(measuredWidth).toInt())
    val layoutText = compatibilityLayoutText(text, paint)
    val layout = StaticLayout.Builder.obtain(
      layoutText,
      0,
      text.length,
      paint,
      layoutWidth,
    )
      .setIncludePad(TextLayoutSpec.includeFontPadding)
      .setBreakStrategy(TextLayoutSpec.breakStrategy)
      .setHyphenationFrequency(TextLayoutSpec.hyphenationFrequency)
      .setTextDirection(TextLayoutSpec.directionHeuristic(text))
      .build()

    val horizontalScale = sourceAdvance / measuredWidth
    if (!horizontalScale.isFinite() ||
      horizontalScale !in minimumCompatibilityHorizontalScale..maximumCompatibilityHorizontalScale
    ) {
      return PdfCompatibilityTextPreparationResult(
        run = null,
        rejection = PdfCompatibilityTextPreparationRejection.SCALE,
        sourceWidth = sourceAdvance,
        sourceHeight = sourceHeight,
        fontSize = fontSize,
        measuredWidth = measuredWidth,
        horizontalScale = horizontalScale,
        layoutWidth = layout.width,
        layoutHeight = layout.height,
      )
    }
    if (layout.lineCount != 1) {
      return PdfCompatibilityTextPreparationResult(
        run = null,
        rejection = PdfCompatibilityTextPreparationRejection.PREPARATION,
        sourceWidth = sourceAdvance,
        sourceHeight = sourceHeight,
        fontSize = fontSize,
        measuredWidth = measuredWidth,
        horizontalScale = horizontalScale,
        layoutWidth = layout.width,
        layoutHeight = layout.height,
      )
    }
    val baseline = sourceTop + layout.getLineBaseline(0)
    return PdfCompatibilityTextPreparationResult(
      run = PdfPreparedCompatibilityTextRun(
        canvasMatrix = CanvasTextMatrix(
          a = horizontalScale,
          b = 0f,
          c = 0f,
          d = 1f,
          // PdfPageTextContent bounds are already top-left page coordinates.
          tx = sourceLeft,
          ty = sourceTop,
        ),
        layout = layout,
        sourceLeft = sourceLeft,
        sourceRight = sourceLeft + sourceAdvance,
        sourceTop = sourceTop,
        sourceBottom = sourceBottom,
        fontSize = fontSize,
        baseline = baseline,
      ),
      measuredWidth = measuredWidth,
      sourceWidth = sourceAdvance,
      sourceHeight = sourceHeight,
      fontSize = fontSize,
      horizontalScale = horizontalScale,
      baseline = baseline,
      layoutWidth = layout.width,
      layoutHeight = layout.height,
    )
  }
}

internal enum class PdfCompatibilityTextPreparationRejection {
  PREPARATION,
  SCALE,
}

internal data class PdfCompatibilityTextPreparationResult(
  val run: PdfPreparedCompatibilityTextRun?,
  val rejection: PdfCompatibilityTextPreparationRejection? = null,
  val measuredWidth: Float? = null,
  val sourceWidth: Float? = null,
  val sourceHeight: Float? = null,
  val fontSize: Float? = null,
  val horizontalScale: Float? = null,
  val baseline: Float? = null,
  val layoutWidth: Int? = null,
  val layoutHeight: Int? = null,
)

/** Prepared presentation reused by every tile and preview in one session. */
internal class PdfPreparedCompatibilityTextRun internal constructor(
  private val canvasMatrix: CanvasTextMatrix,
  private val layout: StaticLayout,
  private val sourceLeft: Float,
  private val sourceRight: Float,
  private val sourceTop: Float,
  private val sourceBottom: Float,
  private val fontSize: Float,
  private val baseline: Float,
) {
  fun draw(canvas: Canvas) {
    canvas.save()
    canvas.concat(canvasMatrix.toAndroidMatrix())
    layout.draw(canvas)
    canvas.restore()
  }

  fun intersects(left: Float, top: Float, right: Float, bottom: Float): Boolean {
    return sourceLeft < right && sourceRight > left &&
      sourceTop < bottom && sourceBottom > top
  }

  fun debugSummary(): String {
    return "rect=$sourceLeft,$sourceTop,$sourceRight,$sourceBottom " +
      "textSize=$fontSize baseline=$baseline " +
      "matrix=${canvasMatrix.a},${canvasMatrix.b},${canvasMatrix.c},${canvasMatrix.d}," +
      "${canvasMatrix.tx},${canvasMatrix.ty} layout=${layout.width}x${layout.height}"
  }
}

private fun compatibilityLayoutText(
  text: String,
  paint: android.text.TextPaint,
): CharSequence {
  val styled = SpannableString(text)
  val scalars = decodePdfScalars(text) ?: return styled
  var offset = 0
  scalars.forEach { scalar ->
    val end = offset + scalar.text.length
    if (isCompatibilityTransparentScalar(scalar.codePoint) || !paint.hasGlyph(scalar.text)) {
      styled.setSpan(
        ForegroundColorSpan(Color.TRANSPARENT),
        offset,
        end,
        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
      )
    }
    offset = end
  }
  return styled
}

internal data class PdfCompatibilityTextExtraction(
  val runs: List<PdfPreparedCompatibilityTextRun>,
  val candidateCount: Int,
  val rejectedGeometryCount: Int,
  val singleRectangleSpanCount: Int,
  val mergedSameLineSpanCount: Int,
  val mergedFragmentCount: Int,
  val rejectedMultiLineMappingCount: Int,
  val rejectedUnusableGeometryCount: Int,
  val preparationRejectionCount: Int,
  val scaleRejectionCount: Int,
  val matchedLineCount: Int,
  val standaloneFallbackCount: Int,
  val unmatchedCandidateCount: Int,
  val diagnostics: List<PdfCompatibilityTextCandidateDiagnostic>,
) {
  val acceptedGroupedRunCount: Int
    get() = runs.size
}

internal enum class PdfCompatibilityTextDisposition {
  ACCEPTED,
  UNUSABLE_GEOMETRY,
  AMBIGUOUS_MULTILINE,
  PREPARATION_FAILURE,
  HORIZONTAL_SCALE_REJECTION,
}

internal data class PdfCompatibilityTextGeometryCluster(
  val memberIndexes: List<Int>,
  val bounds: RectF,
)

internal data class PdfCompatibilityTextRectangleDiagnostic(
  val index: Int,
  val selectionBounds: RectF,
  val matchedLine: PdfCompatibilityTextLine?,
  val standaloneFallback: Boolean,
  val finalBounds: RectF?,
)

internal data class PdfCompatibilityTextCandidateDiagnostic(
  val candidateIndex: Int,
  val geometry: PdfCompatibilityTextGeometry?,
  val disposition: PdfCompatibilityTextDisposition,
  val rectangles: List<PdfCompatibilityTextRectangleDiagnostic>,
  val preparations: List<PdfCompatibilityTextPreparationResult>,
)

internal object PdfCompatibilityTextExtractor {
  fun extract(
    candidateCount: Int,
    spans: List<PdfCompatibilityTextSpan>,
    initialRejectedGeometryCount: Int = 0,
  ): PdfCompatibilityTextExtraction {
    val runs = ArrayList<PdfPreparedCompatibilityTextRun>()
    var rejectedGeometryCount = initialRejectedGeometryCount
    var singleRectangleSpanCount = 0
    var mergedSameLineSpanCount = 0
    var mergedFragmentCount = 0
    var rejectedMultiLineMappingCount = 0
    var rejectedUnusableGeometryCount = 0
    var preparationRejectionCount = 0
    var scaleRejectionCount = 0
    var matchedLineCount = 0
    var standaloneFallbackCount = 0
    var unmatchedCandidateCount = 0
    val diagnostics = ArrayList<PdfCompatibilityTextCandidateDiagnostic>()
    spans.forEach spanLoop@ { span ->
      val resolvedBounds = ArrayList<RectF>(span.bounds.size)
      var hasUnmatchedGeometry = false
      span.bounds.forEachIndexed { index, selectionBounds ->
        val line = span.lineMatches.getOrNull(index)
        when {
          line != null -> {
            matchedLineCount += 1
            resolvedBounds += RectF().apply {
              left = selectionBounds.left
              top = line.bounds.top
              right = selectionBounds.right
              bottom = line.bounds.bottom
            }
          }
          isUsableCompatibilityStandaloneBounds(selectionBounds) -> {
            standaloneFallbackCount += 1
            resolvedBounds += RectF(selectionBounds)
          }
          else -> {
            hasUnmatchedGeometry = true
          }
        }
      }
      if (hasUnmatchedGeometry || resolvedBounds.size != span.bounds.size) {
        rejectedGeometryCount += 1
        rejectedUnusableGeometryCount += 1
        unmatchedCandidateCount += 1
        diagnostics += PdfCompatibilityTextCandidateDiagnostic(
          candidateIndex = span.candidateIndex,
          geometry = null,
          disposition = PdfCompatibilityTextDisposition.UNUSABLE_GEOMETRY,
          rectangles = span.bounds.mapIndexed { index, selectionBounds ->
            PdfCompatibilityTextRectangleDiagnostic(
              index = index,
              selectionBounds = RectF(selectionBounds),
              matchedLine = span.lineMatches.getOrNull(index),
              standaloneFallback = span.lineMatches.getOrNull(index) == null &&
                isUsableCompatibilityStandaloneBounds(selectionBounds),
              finalBounds = null,
            )
          },
          preparations = emptyList(),
        )
        return@spanLoop
      }
      val geometry = mergeCompatibilityTextFragments(span.text, resolvedBounds)
      if (geometry == null) {
        rejectedGeometryCount += 1
        rejectedUnusableGeometryCount += 1
        diagnostics += PdfCompatibilityTextCandidateDiagnostic(
          candidateIndex = span.candidateIndex,
          geometry = null,
          disposition = PdfCompatibilityTextDisposition.UNUSABLE_GEOMETRY,
          rectangles = span.bounds.mapIndexed { index, selectionBounds ->
            PdfCompatibilityTextRectangleDiagnostic(
              index = index,
              selectionBounds = RectF(selectionBounds),
              matchedLine = span.lineMatches.getOrNull(index),
              standaloneFallback = span.lineMatches.getOrNull(index) == null,
              finalBounds = null,
            )
          },
          preparations = emptyList(),
        )
        return@spanLoop
      }
      if (geometry.fragmentCount == 1) singleRectangleSpanCount += 1
      if (geometry.mergedSameLine) {
        mergedSameLineSpanCount += 1
        mergedFragmentCount += geometry.fragmentCount
      }
      if (geometry.textParts == null || geometry.textParts.size != geometry.bounds.size) {
        rejectedGeometryCount += 1
        rejectedMultiLineMappingCount += 1
        diagnostics += PdfCompatibilityTextCandidateDiagnostic(
          candidateIndex = span.candidateIndex,
          geometry = geometry,
          disposition = PdfCompatibilityTextDisposition.AMBIGUOUS_MULTILINE,
          rectangles = emptyList(),
          preparations = emptyList(),
        )
        return@spanLoop
      }
      val preparations = ArrayList<PdfCompatibilityTextPreparationResult>(geometry.bounds.size)
      geometry.bounds.zip(geometry.textParts).forEach partLoop@ { (bounds, text) ->
        if (text.isEmpty()) {
          rejectedGeometryCount += 1
          rejectedMultiLineMappingCount += 1
          return@partLoop
        }
        val preparation = PdfCompatibilityTextRun(text = text, bounds = bounds)
          .prepareWithDiagnostics()
        preparations += preparation
        if (preparation.run == null) {
          rejectedGeometryCount += 1
          when (preparation.rejection) {
            PdfCompatibilityTextPreparationRejection.SCALE -> scaleRejectionCount += 1
            PdfCompatibilityTextPreparationRejection.PREPARATION,
            null -> preparationRejectionCount += 1
          }
        } else {
          runs += preparation.run
        }
      }
      val disposition = when {
        preparations.any {
          it.rejection == PdfCompatibilityTextPreparationRejection.SCALE
        } -> PdfCompatibilityTextDisposition.HORIZONTAL_SCALE_REJECTION
        preparations.any { it.run == null } -> PdfCompatibilityTextDisposition.PREPARATION_FAILURE
        else -> PdfCompatibilityTextDisposition.ACCEPTED
      }
      diagnostics += PdfCompatibilityTextCandidateDiagnostic(
        candidateIndex = span.candidateIndex,
        geometry = geometry,
        disposition = disposition,
        rectangles = span.bounds.mapIndexed { index, selectionBounds ->
          val finalBounds = geometry.clusters.firstOrNull { cluster ->
            index in cluster.memberIndexes
          }?.bounds
          PdfCompatibilityTextRectangleDiagnostic(
            index = index,
            selectionBounds = RectF(selectionBounds),
            matchedLine = span.lineMatches.getOrNull(index),
            standaloneFallback = span.lineMatches.getOrNull(index) == null,
            finalBounds = finalBounds?.let { RectF(it) },
          )
        },
        preparations = preparations.toList(),
      )
    }
    return PdfCompatibilityTextExtraction(
      runs = runs.toList(),
      candidateCount = candidateCount,
      rejectedGeometryCount = rejectedGeometryCount,
      singleRectangleSpanCount = singleRectangleSpanCount,
      mergedSameLineSpanCount = mergedSameLineSpanCount,
      mergedFragmentCount = mergedFragmentCount,
      rejectedMultiLineMappingCount = rejectedMultiLineMappingCount,
      rejectedUnusableGeometryCount = rejectedUnusableGeometryCount,
      preparationRejectionCount = preparationRejectionCount,
      scaleRejectionCount = scaleRejectionCount,
      matchedLineCount = matchedLineCount,
      standaloneFallbackCount = standaloneFallbackCount,
      unmatchedCandidateCount = unmatchedCandidateCount,
      diagnostics = diagnostics.toList(),
    )
  }
}

internal data class PdfCompatibilityTextGeometry(
  val bounds: List<RectF>,
  val textParts: List<String>?,
  val fragmentCount: Int,
  val mergedSameLine: Boolean,
  val clusters: List<PdfCompatibilityTextGeometryCluster>,
)

internal fun mergeCompatibilityTextFragments(
  text: String,
  bounds: List<RectF>,
): PdfCompatibilityTextGeometry? {
  if (bounds.isEmpty()) return null
  val copiedBounds = bounds.mapIndexed { index, bound ->
    PdfCompatibilityIndexedBounds(
      index = index,
      bounds = RectF().apply {
        left = bound.left
        top = bound.top
        right = bound.right
        bottom = bound.bottom
      },
    )
  }
  if (copiedBounds.any { !isUsableCompatibilityBounds(it.bounds) }) return null

  val clusters = ArrayList<MutableList<PdfCompatibilityIndexedBounds>>()
  copiedBounds
    .sortedWith(compareBy<PdfCompatibilityIndexedBounds> { it.bounds.top }.thenBy { it.bounds.left })
    .forEach { bound ->
      val overlapping = clusters.filter { cluster ->
        verticalOverlap(clusterBounds(cluster), bound.bounds)
      }
      if (overlapping.isEmpty()) {
        clusters += arrayListOf(bound)
      } else {
        val mergedCluster = arrayListOf<PdfCompatibilityIndexedBounds>()
        overlapping.forEach { cluster ->
          mergedCluster += cluster
          clusters.remove(cluster)
        }
        mergedCluster += bound
        clusters += mergedCluster
      }
    }

  val orderedClusters = clusters.sortedWith(
    compareBy<List<PdfCompatibilityIndexedBounds>> { clusterBounds(it).top }
      .thenBy { clusterBounds(it).left },
  )
  val unionBounds = orderedClusters.map { cluster -> unionCompatibilityBounds(cluster) }
  val geometryClusters = orderedClusters.map { cluster ->
    PdfCompatibilityTextGeometryCluster(
      memberIndexes = cluster.map { it.index }.sorted(),
      bounds = unionCompatibilityBounds(cluster),
    )
  }
  val textParts = if (unionBounds.size == 1) {
    listOf(text)
  } else {
    splitCompatibilitySpanText(text, unionBounds.size)
  }
  return PdfCompatibilityTextGeometry(
    bounds = unionBounds,
    textParts = textParts,
    fragmentCount = copiedBounds.size,
    mergedSameLine = unionBounds.size == 1 && copiedBounds.size > 1,
    clusters = geometryClusters,
  )
}

private data class PdfCompatibilityIndexedBounds(
  val index: Int,
  val bounds: RectF,
)

private fun clusterBounds(cluster: List<PdfCompatibilityIndexedBounds>): RectF {
  return unionCompatibilityBounds(cluster)
}

private fun verticalOverlap(first: RectF, second: RectF): Boolean {
  return max(first.top, second.top) < min(first.bottom, second.bottom)
}

private fun unionCompatibilityBounds(bounds: List<PdfCompatibilityIndexedBounds>): RectF {
  val first = bounds.first().bounds
  var left = first.left
  var top = first.top
  var right = first.right
  var bottom = first.bottom
  bounds.drop(1).forEach { indexed ->
    val bound = indexed.bounds
    left = min(left, bound.left)
    top = min(top, bound.top)
    right = max(right, bound.right)
    bottom = max(bottom, bound.bottom)
  }
  return RectF().apply {
    this.left = left
    this.top = top
    this.right = right
    this.bottom = bottom
  }
}

private fun isUsableCompatibilityBounds(bounds: RectF): Boolean {
  return bounds.left.isFinite() && bounds.top.isFinite() &&
    bounds.right.isFinite() && bounds.bottom.isFinite() &&
    bounds.right - bounds.left > 1f && bounds.bottom - bounds.top > 1f
}

private fun splitCompatibilitySpanText(text: String, partCount: Int): List<String>? {
  if (partCount <= 0) return null
  if (partCount == 1) return listOf(text)

  val lines = text.split('\n').map { it.removeSuffix("\r") }
  if (lines.size == partCount && lines.all { it.isNotEmpty() }) return lines
  return null
}

internal fun isUsableCompatibilityStandaloneBounds(bounds: RectF): Boolean {
  return bounds.left.isFinite() && bounds.top.isFinite() &&
    bounds.right.isFinite() && bounds.bottom.isFinite() &&
    bounds.right - bounds.left > 1f && bounds.bottom - bounds.top > 1f
}

internal fun isUsableCompatibilityLineBounds(bounds: RectF): Boolean {
  return bounds.left.isFinite() && bounds.top.isFinite() &&
    bounds.right.isFinite() && bounds.bottom.isFinite() &&
    bounds.right > bounds.left && bounds.bottom - bounds.top > 1f
}

internal fun matchCompatibilityTextLine(
  candidateBounds: RectF,
  lines: List<PdfCompatibilityTextLine>,
): PdfCompatibilityTextLine? {
  if (lines.isEmpty()) return null
  val candidateCenterY = (candidateBounds.top + candidateBounds.bottom) * 0.5f
  val verticallyContaining = lines.filter { line ->
    candidateCenterY >= line.bounds.top - 1f &&
      candidateCenterY <= line.bounds.bottom + 1f
  }
  if (verticallyContaining.isEmpty()) return null
  return verticallyContaining.minWithOrNull(
    compareByDescending<PdfCompatibilityTextLine> { line ->
      horizontalCompatibilityOverlap(candidateBounds, line.bounds)
    }.thenBy { line ->
      kotlin.math.abs(candidateCenterY - (line.bounds.top + line.bounds.bottom) * 0.5f)
    }.thenBy { line -> line.index },
  )
}

private fun horizontalCompatibilityOverlap(first: RectF, second: RectF): Float {
  return max(0f, min(first.right, second.right) - max(first.left, second.left))
}

internal fun formatCompatibilityCodePoints(text: String): String {
  val scalars = decodePdfScalars(text) ?: return "invalid"
  return scalars.joinToString(prefix = "[", postfix = "]", separator = ",") {
    "U+${it.codePoint.toString(16).uppercase(Locale.ROOT)}"
  }
}

internal fun formatCompatibilityCodePointSummary(text: String): String {
  val scalars = decodePdfScalars(text) ?: return "count=-1 invalid=true"
  if (scalars.size <= 24) {
    return "count=${scalars.size} codePoints=${formatCompatibilityCodePoints(text)}"
  }
  val first = scalars.take(12).joinToString(prefix = "[", postfix = "]", separator = ",") {
    "U+${it.codePoint.toString(16).uppercase(Locale.ROOT)}"
  }
  val last = scalars.takeLast(12).joinToString(prefix = "[", postfix = "]", separator = ",") {
    "U+${it.codePoint.toString(16).uppercase(Locale.ROOT)}"
  }
  return "count=${scalars.size} first=$first last=$last truncated=true"
}

internal fun formatCompatibilityRect(bounds: RectF): String {
  return "[${bounds.left},${bounds.top},${bounds.right},${bounds.bottom}]"
}

internal object PdfCompatibilityMapLogger {
  private const val tag = "InkSignPdfMap"

  fun log(message: String) {
    if (BuildConfig.DEBUG) Log.d(tag, message)
  }
}

internal object PdfCompatibilityTextRenderer {
  fun draw(
    canvas: Canvas,
    request: PdfTileRequest,
    runs: List<PdfPreparedCompatibilityTextRun>,
  ) {
    if (runs.isEmpty()) return
    val tileMatrix = Matrix().apply {
      setValues(floatArrayOf(
        request.scale.toFloat(), 0f, -request.leftPx.toFloat(),
        0f, request.scale.toFloat(), -request.topPx.toFloat(),
        0f, 0f, 1f,
      ))
    }
    val pageLeft = request.leftPx.toFloat() / request.scale.toFloat()
    val pageTop = request.topPx.toFloat() / request.scale.toFloat()
    val pageRight = (request.leftPx + request.widthPx).toFloat() / request.scale.toFloat()
    val pageBottom = (request.topPx + request.heightPx).toFloat() / request.scale.toFloat()
    canvas.save()
    canvas.concat(tileMatrix)
    runs.forEach { run ->
      if (run.intersects(pageLeft, pageTop, pageRight, pageBottom)) run.draw(canvas)
    }
    canvas.restore()
  }
}

internal data class PdfUnicodeScalar(
  val codePoint: Int,
  val text: String,
)

internal data class PdfCompatibilityTextCandidate(
  val start: Int,
  val end: Int,
  val text: String,
)

internal fun decodePdfScalars(text: String): List<PdfUnicodeScalar>? {
  val scalars = ArrayList<PdfUnicodeScalar>()
  var index = 0
  while (index < text.length) {
    val first = text[index].code
    if (first in 0xD800..0xDBFF) {
      if (index + 1 >= text.length) return null
      val second = text[index + 1].code
      if (second !in 0xDC00..0xDFFF) return null
      val codePoint = Character.toCodePoint(first.toChar(), second.toChar())
      scalars += PdfUnicodeScalar(codePoint, text.substring(index, index + 2))
      index += 2
    } else if (first in 0xDC00..0xDFFF) {
      return null
    } else {
      scalars += PdfUnicodeScalar(first, text.substring(index, index + 1))
      index += 1
    }
  }
  return scalars
}

internal fun isCompatibilityTransparentScalar(codePoint: Int): Boolean {
  return codePoint <= 0x1F ||
    codePoint in 0x20..0x7E ||
    codePoint in 0x7F..0x9F ||
    Character.isWhitespace(codePoint) ||
    Character.isSpaceChar(codePoint)
}

internal fun groupCompatibilityTextCandidates(
  text: String,
  hasGlyph: ((String) -> Boolean)? = null,
): List<PdfCompatibilityTextCandidate> {
  val scalars = decodePdfScalars(text) ?: return emptyList()
  if (scalars.isEmpty()) return emptyList()
  val glyphPaint = if (hasGlyph == null) TextLayoutSpec.createPaint(16.0) else null

  val offsets = IntArray(scalars.size + 1)
  var offset = 0
  scalars.forEachIndexed { index, scalar ->
    offsets[index] = offset
    offset += scalar.text.length
  }
  offsets[scalars.size] = offset

  fun isCandidate(index: Int): Boolean {
    val scalar = scalars[index]
    return scalar.codePoint > 0x9F &&
      !isCompatibilityTransparentScalar(scalar.codePoint) &&
      (hasGlyph?.invoke(scalar.text) ?: glyphPaint!!.hasGlyph(scalar.text))
  }

  val candidates = BooleanArray(scalars.size) { index -> isCandidate(index) }
  val grouped = ArrayList<PdfCompatibilityTextCandidate>()
  var index = 0
  while (index < scalars.size) {
    if (!candidates[index]) {
      index += 1
      continue
    }

    val startIndex = index
    var endIndex = index + 1
    index += 1
    while (index < scalars.size) {
      if (candidates[index]) {
        endIndex = index + 1
        index += 1
        continue
      }
      if (isCompatibilitySpanJoiner(scalars[index].codePoint) &&
        index + 1 < scalars.size && candidates[index + 1]
      ) {
        endIndex = index + 2
        index += 2
        continue
      }
      break
    }
    grouped += PdfCompatibilityTextCandidate(
      start = offsets[startIndex],
      end = offsets[endIndex],
      text = text.substring(offsets[startIndex], offsets[endIndex]),
    )
  }
  return grouped
}

private fun isCompatibilitySpanJoiner(codePoint: Int): Boolean {
  if (codePoint == '\n'.code || codePoint == '\r'.code) return false
  if (Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint)) return true
  return when (Character.getType(codePoint)) {
    Character.CONNECTOR_PUNCTUATION.toInt(),
    Character.DASH_PUNCTUATION.toInt(),
    Character.END_PUNCTUATION.toInt(),
    Character.FINAL_QUOTE_PUNCTUATION.toInt(),
    Character.INITIAL_QUOTE_PUNCTUATION.toInt(),
    Character.OTHER_PUNCTUATION.toInt(),
    Character.START_PUNCTUATION.toInt() -> true
    else -> false
  }
}

internal fun hasPaintableCompatibilityScalar(
  text: String,
  hasGlyph: (String) -> Boolean,
): Boolean {
  return decodePdfScalars(text)?.any { scalar ->
    !isCompatibilityTransparentScalar(scalar.codePoint) && hasGlyph(scalar.text)
  } == true
}
