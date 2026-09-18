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
import kotlin.math.ceil
import kotlin.math.max

private val compatibilityTypeface = Typeface.DEFAULT
private const val minimumCompatibilityHorizontalScale = 0.5f
private const val maximumCompatibilityHorizontalScale = 2.0f

/** A copied logical text span selected from one worker-owned PDF page. */
internal data class PdfCompatibilityTextSpan(
  val text: String,
  val bounds: List<RectF>,
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
    ) return null

    val fontSize = sourceHeight / probeMetricHeight
    if (!fontSize.isFinite() || fontSize <= 0f) return null
    val paint = TextLayoutSpec.createPaint(fontSize.toDouble(), typeface = compatibilityTypeface)
    val measuredWidth = paint.measureText(text)
    if (!measuredWidth.isFinite() || measuredWidth <= 0f) return null
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
    ) return null
    if (layout.lineCount != 1) return null
    val baseline = sourceTop + layout.getLineBaseline(0)
    return PdfPreparedCompatibilityTextRun(
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
    )
  }
}

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
) {
  val acceptedGroupedRunCount: Int
    get() = runs.size
}

internal object PdfCompatibilityTextExtractor {
  fun extract(
    candidateCount: Int,
    spans: List<PdfCompatibilityTextSpan>,
    initialRejectedGeometryCount: Int = 0,
  ): PdfCompatibilityTextExtraction {
    val runs = ArrayList<PdfPreparedCompatibilityTextRun>()
    var rejectedGeometryCount = initialRejectedGeometryCount
    spans.forEach { span ->
      val copiedBounds = span.bounds
        .filter(::isUsableCompatibilityBounds)
        .map { RectF(it) }
      if (copiedBounds.isEmpty()) {
        rejectedGeometryCount += 1
        return@forEach
      }
      val textParts = splitCompatibilitySpanText(span.text, copiedBounds.size)
      if (textParts == null || textParts.size != copiedBounds.size) {
        rejectedGeometryCount += 1
        return@forEach
      }
      copiedBounds.zip(textParts).forEach { (bounds, text) ->
        if (text.isEmpty()) {
          rejectedGeometryCount += 1
          return@forEach
        }
        val prepared = PdfCompatibilityTextRun(text = text, bounds = bounds).prepare()
        if (prepared == null) rejectedGeometryCount += 1 else runs += prepared
      }
    }
    return PdfCompatibilityTextExtraction(
      runs = runs.toList(),
      candidateCount = candidateCount,
      rejectedGeometryCount = rejectedGeometryCount,
    )
  }
}

private fun isUsableCompatibilityBounds(bounds: RectF): Boolean {
  return bounds.left.isFinite() && bounds.top.isFinite() &&
    bounds.right.isFinite() && bounds.bottom.isFinite() &&
    bounds.width() > 1f && bounds.height() > 1f
}

private fun splitCompatibilitySpanText(text: String, partCount: Int): List<String>? {
  if (partCount <= 0) return null
  if (partCount == 1) return listOf(text)

  val lines = text.split('\n')
  if (lines.size == partCount && lines.all { it.isNotEmpty() }) return lines
  return null
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
