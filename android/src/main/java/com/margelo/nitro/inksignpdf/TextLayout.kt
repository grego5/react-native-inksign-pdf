package com.margelo.nitro.inksignpdf

import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextDirectionHeuristic
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.widget.TextView
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * The shared text-layout contract for page rendering, previews, hit bounds,
 * and the temporary editor.
 */
internal data class TextIntrinsicSize(
  val width: Double,
  val height: Double,
)

/**
 * Materializes only native soft-wrap boundaries as explicit newlines.
 * Existing newline boundaries are left untouched, so applying this twice is
 * idempotent.
 */
internal fun materializeSoftWraps(
  text: String,
  lineStarts: List<Int>,
  lineEnds: List<Int>,
): String {
  if (text.isEmpty() || lineEnds.size < 2 || lineStarts.size < 2) return text
  val breaks = HashSet<Int>()
  val boundaryCount = minOf(lineEnds.size - 1, lineStarts.size - 1)
  repeat(boundaryCount) { line ->
    val end = lineEnds[line].coerceIn(0, text.length)
    val nextStart = lineStarts[line + 1].coerceIn(0, text.length)
    if (nextStart == end && end > 0 && end < text.length &&
      text[end - 1] != '\n' && text[end - 1] != '\r' && text[end] != '\n' && text[end] != '\r'
    ) {
      breaks += end
    }
  }
  if (breaks.isEmpty()) return text
  return buildString(text.length + breaks.size) {
    text.forEachIndexed { index, character ->
      if (index in breaks) append('\n')
      append(character)
    }
  }
}

internal object TextLayoutSpec {
  val typeface: Typeface = Typeface.DEFAULT
  const val includeFontPadding = false
  const val lineSpacingExtra = 0f
  const val lineSpacingMultiplier = 1f
  const val breakStrategy = Layout.BREAK_STRATEGY_SIMPLE
  const val hyphenationFrequency = Layout.HYPHENATION_FREQUENCY_NONE

  /** Forces the saved paragraph base direction while Android resolves embedded bidi runs. */
  fun directionHeuristic(baseDirectionRtl: Boolean): TextDirectionHeuristic =
    if (baseDirectionRtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR

  fun explicitLines(text: String): List<String> =
    text.split("\n", ignoreCase = false, limit = Int.MAX_VALUE)

  fun createPaint(
    fontSize: Double,
    color: Int = Color.BLACK,
    typeface: Typeface = TextLayoutSpec.typeface,
  ): TextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
    this.typeface = typeface
    textSize = fontSize.toFloat()
    this.color = color
  }

  fun measure(
    text: String,
    fontSize: Double,
    typeface: Typeface = TextLayoutSpec.typeface,
  ): TextIntrinsicSize {
    require(fontSize.isFinite() && fontSize > 0.0)
    val paint = createPaint(fontSize, typeface = typeface)
    val lines = explicitLines(text)
    val width = lines.maxOfOrNull { line ->
      paint.measureText(line.trimEnd('\r')).toDouble()
    } ?: 0.0
    val metrics = paint.fontMetrics
    val lineHeight = (metrics.descent - metrics.ascent).toDouble()
    return TextIntrinsicSize(
      width = max(width, fontSize * 0.25),
      height = max(lineHeight * lines.size, lineHeight),
    )
  }

  /** Measures the live editor after applying its page-edge width constraint. */
  fun measureWrapped(
    text: String,
    fontSize: Double,
    width: Double,
    baseDirectionRtl: Boolean,
  ): TextIntrinsicSize {
    require(width.isFinite() && width > 0.0)
    val layoutWidth = max(1, ceil(width).toInt())
    val layout = StaticLayout.Builder.obtain(
      text,
      0,
      text.length,
      createPaint(fontSize),
      layoutWidth,
    )
      .setIncludePad(includeFontPadding)
      .setBreakStrategy(breakStrategy)
      .setHyphenationFrequency(hyphenationFrequency)
      .setTextDirection(directionHeuristic(baseDirectionRtl))
      .build()
    return TextIntrinsicSize(width, max(layout.height.toDouble(), measure(text, fontSize).height))
  }

  fun createLayout(annotation: TextAnnotation): StaticLayout {
    val paint = createPaint(annotation.fontSize, annotation.textColor)
    val measuredWidth = measure(annotation.text, annotation.fontSize).width
    val layoutWidth = annotation.flowBounds?.let { it.right - it.left }
      ?: max(annotation.intrinsicWidth, measuredWidth)
    val width = max(1, ceil(layoutWidth).toInt())
    return StaticLayout.Builder.obtain(
      annotation.text,
      0,
      annotation.text.length,
      paint,
      width,
    )
      .setIncludePad(includeFontPadding)
      .setBreakStrategy(breakStrategy)
      .setHyphenationFrequency(hyphenationFrequency)
      .setTextDirection(directionHeuristic(annotation.directionRtl))
      .build()
  }

  fun visibleBounds(annotation: TextAnnotation, flowBounds: PageRect): PageRect {
    val layout = createLayout(annotation)
    val flowWidth = flowBounds.right - flowBounds.left
    val flowHeight = flowBounds.bottom - flowBounds.top
    val visibleHeight = completeLineHeight(layout, flowHeight)
    var left = flowWidth
    var right = 0.0
    var bottom = 0.0
    for (lineIndex in 0 until layout.lineCount) {
      if (layout.getLineBottom(lineIndex).toDouble() > visibleHeight) break
      left = min(left, layout.getLineLeft(lineIndex).toDouble().coerceIn(0.0, flowWidth))
      right = max(right, layout.getLineRight(lineIndex).toDouble().coerceIn(0.0, flowWidth))
      bottom = max(bottom, min(flowHeight, layout.getLineBottom(lineIndex).toDouble()))
    }
    if (left > right) left = right
    return PageRect(
      flowBounds.left + left,
      flowBounds.top,
      flowBounds.left + right,
      flowBounds.top + bottom,
    )
  }

  fun completeLineHeight(layout: StaticLayout, flowHeight: Double): Double {
    var visibleHeight = 0.0
    for (lineIndex in 0 until layout.lineCount) {
      val lineBottom = layout.getLineBottom(lineIndex).toDouble()
      if (lineBottom > flowHeight) break
      visibleHeight = lineBottom
    }
    return visibleHeight
  }

  fun configureEditor(
    editor: TextView,
    fontSize: Double,
    baseDirectionRtl: Boolean,
    horizontalPaddingPx: Int = 0,
    verticalPaddingPx: Int = 0,
    textColor: Int = Color.BLACK,
  ) {
    editor.typeface = typeface
    editor.setTextColor(textColor)
    editor.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, fontSize.toFloat())
    editor.includeFontPadding = includeFontPadding
    editor.setLineSpacing(lineSpacingExtra, lineSpacingMultiplier)
    editor.breakStrategy = breakStrategy
    editor.hyphenationFrequency = hyphenationFrequency
    configureEditorDirection(editor, baseDirectionRtl)
    editor.setPadding(
      horizontalPaddingPx,
      verticalPaddingPx,
      horizontalPaddingPx,
      verticalPaddingPx,
    )
  }

  fun configureEditorDirection(
    editor: TextView,
    baseDirectionRtl: Boolean,
  ) {
    val direction = if (baseDirectionRtl) TextView.TEXT_DIRECTION_RTL else TextView.TEXT_DIRECTION_LTR
    if (editor.textDirection != direction) editor.textDirection = direction
    val gravity = android.view.Gravity.TOP or if (baseDirectionRtl) {
      android.view.Gravity.RIGHT
    } else {
      android.view.Gravity.LEFT
    }
    if (editor.gravity != gravity) editor.gravity = gravity
  }
}

/** Immutable layouts derived from one committed annotation snapshot. */
internal class TextRenderLayer private constructor(
  private val entries: List<Entry>,
) {
  private data class Entry(
    val annotation: TextAnnotation,
    val layout: StaticLayout,
    val clipBounds: PageRect?,
  )

  fun draw(canvas: android.graphics.Canvas, excludedAnnotationId: String? = null) {
    entries.forEach { entry ->
      if (entry.annotation.id == excludedAnnotationId) return@forEach
      canvas.save()
      canvas.translate(
        (entry.clipBounds?.left ?: entry.annotation.position.x).toFloat(),
        (entry.clipBounds?.top ?: entry.annotation.position.y).toFloat(),
      )
      entry.clipBounds?.let { bounds ->
        canvas.clipRect(
          0f,
          0f,
          (bounds.right - bounds.left).toFloat(),
          (bounds.bottom - bounds.top).toFloat(),
        )
      }
      entry.layout.draw(canvas)
      canvas.restore()
    }
  }

  companion object {
    fun empty(): TextRenderLayer = TextRenderLayer(emptyList())

    fun from(annotations: List<TextAnnotation>): TextRenderLayer {
      return TextRenderLayer(
        annotations.map { annotation ->
          val layout = TextLayoutSpec.createLayout(annotation)
          val clipBounds = annotation.flowBounds?.let { bounds ->
            val visibleHeight = TextLayoutSpec.completeLineHeight(
              layout,
              bounds.bottom - bounds.top,
            )
            PageRect(bounds.left, bounds.top, bounds.right, bounds.top + visibleHeight)
          }
          Entry(annotation, layout, clipBounds)
        },
      )
    }
  }
}
