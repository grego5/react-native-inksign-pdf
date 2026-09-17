package com.margelo.nitro.inksignpdf

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.RectF
import android.text.StaticLayout
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** A copied selection boundary point in the page's top-left coordinate space. */
internal data class PdfCompatibilityPoint(
  val x: Float,
  val y: Float,
)

/** The scalar and the resolved visual interval returned by Android selection. */
internal data class PdfCompatibilityScalarSelection(
  val scalar: PdfUnicodeScalar,
  val start: PdfCompatibilityPoint?,
  val stop: PdfCompatibilityPoint?,
)

/** The affine transform from page coordinates to the prepared layout. */
internal data class CanvasTextMatrix(
  val a: Float,
  val b: Float,
  val c: Float,
  val d: Float,
  val tx: Float,
  val ty: Float,
) {
  fun toAndroidMatrix(): Matrix {
    return Matrix().apply {
      setValues(floatArrayOf(
        a, c, tx,
        b, d, ty,
        0f, 0f, 1f,
      ))
    }
  }
}

internal data class PdfCompatibilityTextRun(
  val text: String,
  val sourceLeft: Float,
  val sourceTop: Float,
  val sourceAdvance: Float,
  val fontSize: Float,
) {
  fun prepare(): PdfPreparedCompatibilityTextRun {
    val paint = TextLayoutSpec.createPaint(fontSize.toDouble())
    val measuredWidth = paint.measureText(text)
    val layoutWidth = max(1, ceil(measuredWidth).toInt())
    val layout = StaticLayout.Builder.obtain(
      text,
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

    val horizontalScale = if (sourceAdvance.isFinite() && sourceAdvance > 0f &&
      measuredWidth.isFinite() && measuredWidth > 0f
    ) {
      sourceAdvance / measuredWidth
    } else {
      1f
    }
    return PdfPreparedCompatibilityTextRun(
      canvasMatrix = CanvasTextMatrix(
        a = horizontalScale,
        b = 0f,
        c = 0f,
        d = 1f,
        // SelectionBoundary points are already top-left page coordinates.
        tx = sourceLeft,
        ty = sourceTop,
      ),
      layout = layout,
      sourceLeft = sourceLeft,
      sourceRight = sourceLeft + sourceAdvance,
      lineHeight = fontSize,
    )
  }
}

/** Prepared presentation reused by every tile and preview in one session. */
internal class PdfPreparedCompatibilityTextRun internal constructor(
  private val canvasMatrix: CanvasTextMatrix,
  private val layout: StaticLayout,
  private val sourceLeft: Float,
  private val sourceRight: Float,
  private val lineHeight: Float,
) {
  fun draw(canvas: Canvas) {
    canvas.save()
    canvas.concat(canvasMatrix.toAndroidMatrix())
    layout.draw(canvas)
    canvas.restore()
  }

  fun debugSummary(): String {
    return "interval=$sourceLeft..$sourceRight lineHeight=$lineHeight " +
      "matrix=${canvasMatrix.a},${canvasMatrix.b},${canvasMatrix.c},${canvasMatrix.d}," +
      "${canvasMatrix.tx},${canvasMatrix.ty} layout=${layout.width}x${layout.height}"
  }
}

internal data class PdfCompatibilityTextExtraction(
  val runs: List<PdfPreparedCompatibilityTextRun>,
  val skippedUniversalCount: Int,
  val missingGlyphCount: Int,
  val missingBoundaryCount: Int,
  val unmatchedLineCount: Int,
) {
  val geometryFailureCount: Int
    get() = missingBoundaryCount + unmatchedLineCount
}

internal object PdfCompatibilityTextExtractor {
  fun extract(
    lineBounds: List<RectF>,
    selections: List<PdfCompatibilityScalarSelection>,
  ): PdfCompatibilityTextExtraction {
    val runs = ArrayList<PdfPreparedCompatibilityTextRun>()
    var skippedUniversalCount = 0
    var missingGlyphCount = 0
    var missingBoundaryCount = 0
    var unmatchedLineCount = 0

    val copiedLines = lineBounds
      .filter(::isUsableCompatibilityBounds)
      .map { RectF(it) }
    selections.forEach { selection ->
      val scalar = selection.scalar
      if (isCompatibilityTransparentScalar(scalar.codePoint)) {
        skippedUniversalCount += 1
        return@forEach
      }

      val start = selection.start
      val stop = selection.stop
      if (start == null || stop == null ||
        !isFiniteCompatibilityPoint(start) || !isFiniteCompatibilityPoint(stop)
      ) {
        missingBoundaryCount += 1
        return@forEach
      }

      val line = findContainingLine(copiedLines, start, stop)
      if (line == null) {
        unmatchedLineCount += 1
        return@forEach
      }

      val fontSize = line.height()
      val paint = TextLayoutSpec.createPaint(fontSize.toDouble())
      if (!paint.hasGlyph(scalar.text)) {
        missingGlyphCount += 1
        return@forEach
      }

      val left = min(start.x, stop.x)
      val right = max(start.x, stop.x)
      if (!left.isFinite() || !right.isFinite() || !fontSize.isFinite() || fontSize <= 0f) {
        unmatchedLineCount += 1
        return@forEach
      }
      runs += PdfCompatibilityTextRun(
        text = scalar.text,
        sourceLeft = left,
        sourceTop = line.top,
        sourceAdvance = right - left,
        fontSize = fontSize,
      ).prepare()
    }
    return PdfCompatibilityTextExtraction(
      runs = runs.toList(),
      skippedUniversalCount = skippedUniversalCount,
      missingGlyphCount = missingGlyphCount,
      missingBoundaryCount = missingBoundaryCount,
      unmatchedLineCount = unmatchedLineCount,
    )
  }
}

private fun findContainingLine(
  lines: List<RectF>,
  start: PdfCompatibilityPoint,
  stop: PdfCompatibilityPoint,
): RectF? {
  val midpointY = (start.y + stop.y) * 0.5f
  return lines
    .filter { line ->
      containsY(line, start.y) || containsY(line, stop.y) ||
        containsPoint(line, start) || containsPoint(line, stop)
    }
    .minByOrNull { line ->
      kotlin.math.abs((line.top + line.bottom) * 0.5f - midpointY)
    }
}

private fun containsY(line: RectF, y: Float): Boolean {
  return y >= line.top && y <= line.bottom
}

private fun containsPoint(line: RectF, point: PdfCompatibilityPoint): Boolean {
  return point.x >= line.left && point.x <= line.right && containsY(line, point.y)
}

private fun isFiniteCompatibilityPoint(point: PdfCompatibilityPoint): Boolean {
  return point.x.isFinite() && point.y.isFinite()
}

private fun isUsableCompatibilityBounds(bounds: RectF): Boolean {
  return bounds.left.isFinite() && bounds.top.isFinite() &&
    bounds.right.isFinite() && bounds.bottom.isFinite() &&
    bounds.width() > 0f && bounds.height() > 0f
}

internal fun compatibilityCodePointSummary(text: String): String {
  return decodePdfScalars(text)
    ?.asSequence()
    ?.filterNot { isCompatibilityTransparentScalar(it.codePoint) }
    ?.take(12)
    ?.joinToString(separator = ",") { "U+${it.codePoint.toString(16).uppercase()}" }
    .orEmpty()
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
    canvas.save()
    canvas.concat(tileMatrix)
    runs.forEach { run -> run.draw(canvas) }
    canvas.restore()
  }
}

internal data class PdfUnicodeScalar(
  val codePoint: Int,
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

internal fun hasPaintableCompatibilityScalar(
  text: String,
  hasGlyph: (String) -> Boolean,
): Boolean {
  return decodePdfScalars(text)?.any { scalar ->
    !isCompatibilityTransparentScalar(scalar.codePoint) && hasGlyph(scalar.text)
  } == true
}
