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

internal data class VisibleTextLineSelection(
  val lineCount: Int,
  val height: Double,
  val topOffset: Double,
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
    val measuredWidth = measure(annotation.text, annotation.fontSize).width
    val layoutWidth = annotation.flowBounds?.let { it.right - it.left }
      ?: max(annotation.intrinsicWidth, measuredWidth)
    return createLayout(
      text = annotation.text,
      fontSize = annotation.fontSize,
      textColor = annotation.textColor,
      layoutWidth = layoutWidth,
      baseDirectionRtl = annotation.directionRtl,
      alignment = annotation.alignment,
    )
  }

  fun createLayout(
    text: String,
    fontSize: Double,
    textColor: Int,
    layoutWidth: Double,
    baseDirectionRtl: Boolean,
    alignment: TextAlignment = TextAlignment.START,
  ): StaticLayout {
    val paint = createPaint(fontSize, textColor)
    val width = max(1, ceil(layoutWidth).toInt())
    return StaticLayout.Builder.obtain(
      text,
      0,
      text.length,
      paint,
      width,
    )
      .setIncludePad(includeFontPadding)
      .setBreakStrategy(breakStrategy)
      .setHyphenationFrequency(hyphenationFrequency)
      .setTextDirection(directionHeuristic(baseDirectionRtl))
      .setAlignment(when (alignment) {
        TextAlignment.CENTER -> android.text.Layout.Alignment.ALIGN_CENTER
        TextAlignment.START -> android.text.Layout.Alignment.ALIGN_NORMAL
        TextAlignment.END -> android.text.Layout.Alignment.ALIGN_OPPOSITE
      })
      .build()
  }

  /** Whether an editor value can be shown completely inside its configured flow region. */
  fun fitsFlow(
    text: String,
    fontSize: Double,
    textColor: Int,
    flowBounds: PageRect,
    maxLines: Int,
    baseDirectionRtl: Boolean,
    alignment: TextAlignment = TextAlignment.START,
  ): Boolean {
    if (text.isEmpty()) return true
    val layout = createLayout(
      text = text,
      fontSize = fontSize,
      textColor = textColor,
      layoutWidth = flowBounds.right - flowBounds.left,
      baseDirectionRtl = baseDirectionRtl,
      alignment = alignment,
    )
    val selection = selectVisibleLines(
      layout = layout,
      flowBounds = flowBounds,
      maxLines = maxLines,
      // The anchor shifts a clipped block vertically; it never changes the fit test.
      verticalAnchor = TextVerticalAnchor.TOP,
    )
    return selection.lineCount == layout.lineCount
  }

  /** Applies an explicit line cap while preserving intrinsic-width auto-sizing. */
  fun fitsMaxLines(
    text: String,
    fontSize: Double,
    textColor: Int,
    maxLines: Int,
    baseDirectionRtl: Boolean,
    alignment: TextAlignment,
  ): Boolean {
    if (text.isEmpty() || maxLines <= 0) return true
    val intrinsicWidth = measure(text, fontSize).width
    return createLayout(
      text = text,
      fontSize = fontSize,
      textColor = textColor,
      layoutWidth = intrinsicWidth,
      baseDirectionRtl = baseDirectionRtl,
      alignment = alignment,
    ).lineCount <= maxLines
  }

  fun selectVisibleLines(
    layout: StaticLayout,
    flowBounds: PageRect,
    maxLines: Int,
    verticalAnchor: TextVerticalAnchor,
  ): VisibleTextLineSelection {
    val flowHeight = flowBounds.bottom - flowBounds.top
    var lineCount = 0
    var visibleHeight = 0.0
    for (lineIndex in 0 until layout.lineCount) {
      if ((maxLines > 0 && lineCount >= maxLines) ||
        layout.getLineBottom(lineIndex).toDouble() > flowHeight
      ) break
      lineCount += 1
      visibleHeight = layout.getLineBottom(lineIndex).toDouble()
    }
    return VisibleTextLineSelection(
      lineCount = lineCount,
      height = visibleHeight,
      topOffset = if (verticalAnchor == TextVerticalAnchor.BOTTOM) flowHeight - visibleHeight else 0.0,
    )
  }

  fun visibleBounds(annotation: TextAnnotation, flowBounds: PageRect): PageRect {
    val layout = createLayout(annotation)
    val flowWidth = flowBounds.right - flowBounds.left
    val selection = selectVisibleLines(
      layout,
      flowBounds,
      annotation.maxLines,
      annotation.verticalAnchor,
    )
    var left = flowWidth
    var right = 0.0
    for (lineIndex in 0 until selection.lineCount) {
      left = min(left, layout.getLineLeft(lineIndex).toDouble().coerceIn(0.0, flowWidth))
      right = max(right, layout.getLineRight(lineIndex).toDouble().coerceIn(0.0, flowWidth))
    }
    if (left > right) left = right
    val top = flowBounds.top + selection.topOffset
    return PageRect(
      flowBounds.left + left,
      top,
      flowBounds.left + right,
      top + selection.height,
    )
  }

  fun configureEditor(
    editor: TextView,
    fontSize: Double,
    baseDirectionRtl: Boolean,
    horizontalPaddingPx: Int = 0,
    verticalPaddingPx: Int = 0,
    textColor: Int = Color.BLACK,
    alignment: TextAlignment = TextAlignment.START,
  ) {
    editor.typeface = typeface
    editor.setTextColor(textColor)
    editor.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, fontSize.toFloat())
    editor.includeFontPadding = includeFontPadding
    editor.setLineSpacing(lineSpacingExtra, lineSpacingMultiplier)
    editor.breakStrategy = breakStrategy
    editor.hyphenationFrequency = hyphenationFrequency
    configureEditorDirection(editor, baseDirectionRtl, alignment)
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
    alignment: TextAlignment = TextAlignment.START,
  ) {
    val direction = if (baseDirectionRtl) TextView.TEXT_DIRECTION_RTL else TextView.TEXT_DIRECTION_LTR
    if (editor.textDirection != direction) editor.textDirection = direction
    val resolvedAlignment = when (alignment) {
      TextAlignment.CENTER -> android.view.Gravity.CENTER_HORIZONTAL
      TextAlignment.START -> if (baseDirectionRtl) android.view.Gravity.RIGHT else android.view.Gravity.LEFT
      TextAlignment.END -> if (baseDirectionRtl) android.view.Gravity.LEFT else android.view.Gravity.RIGHT
    }
    val gravity = android.view.Gravity.TOP or resolvedAlignment
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
    val flowBounds: PageRect?,
    val selection: VisibleTextLineSelection?,
  )

  fun draw(
    canvas: android.graphics.Canvas,
    excludedAnnotationId: Long? = null,
    inLayoutSpace: Boolean = false,
  ) {
    entries.forEach { entry ->
      if (entry.annotation.id == excludedAnnotationId) return@forEach
      val flowBounds = entry.flowBounds
      val selection = entry.selection
      if (flowBounds != null && selection != null && selection.lineCount == 0) return@forEach
      canvas.save()
      if (!inLayoutSpace) entry.annotation.layoutPage?.let {
        canvas.concat(PageCoordinates(it).displayToRawTransform().toCanvasMatrix())
      }
      if (flowBounds == null) {
        canvas.translate(entry.annotation.bounds.left.toFloat(), entry.annotation.bounds.top.toFloat())
        val maxLines = entry.annotation.maxLines
        if (maxLines > 0 && entry.layout.lineCount > maxLines) {
          canvas.clipRect(
            0f,
            0f,
            entry.layout.width.toFloat(),
            entry.layout.getLineBottom(maxLines - 1).toFloat(),
          )
        }
      } else {
        val visible = checkNotNull(selection)
        canvas.translate(flowBounds.left.toFloat(), flowBounds.top.toFloat())
        canvas.clipRect(
          0f,
          visible.topOffset.toFloat(),
          (flowBounds.right - flowBounds.left).toFloat(),
          (visible.topOffset + visible.height).toFloat(),
        )
        canvas.translate(0f, visible.topOffset.toFloat())
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
          val selection = annotation.flowBounds?.let { bounds ->
            TextLayoutSpec.selectVisibleLines(
              layout,
              bounds,
              annotation.maxLines,
              annotation.verticalAnchor,
            )
          }
          Entry(annotation, layout, annotation.flowBounds, selection)
        },
      )
    }
  }
}
