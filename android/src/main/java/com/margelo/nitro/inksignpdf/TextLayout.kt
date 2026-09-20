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
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max

/**
 * The shared text-layout contract for page rendering, previews, hit bounds,
 * and the temporary editor.
 */
internal data class TextIntrinsicSize(
  val width: Double,
  val height: Double,
)

private fun firstStrongTextDirectionIsRtl(text: CharSequence): Boolean? {
  var index = 0
  while (index < text.length) {
    val codePoint = Character.codePointAt(text, index)
    when (Character.getDirectionality(codePoint)) {
      Character.DIRECTIONALITY_LEFT_TO_RIGHT -> return false
      Character.DIRECTIONALITY_RIGHT_TO_LEFT,
      Character.DIRECTIONALITY_RIGHT_TO_LEFT_ARABIC -> return true
    }
    index += Character.charCount(codePoint)
  }
  return null
}

private fun localeTextDirectionIsRtl(): Boolean {
  return try {
    android.text.TextUtils.getLayoutDirectionFromLocale(Locale.getDefault()) == android.view.View.LAYOUT_DIRECTION_RTL
  } catch (_: RuntimeException) {
    Locale.getDefault().language in setOf("ar", "fa", "he", "iw", "ur", "ps", "sd", "ug", "yi")
  }
}

/** Resolves the first-strong paragraph direction with locale fallback. */
internal fun textIsRtl(text: CharSequence): Boolean = firstStrongTextDirectionIsRtl(text)
  ?: localeTextDirectionIsRtl()

/** Uses a caller-owned direction when the text has no strong character. */
internal fun textDirectionIsRtl(text: CharSequence, emptyDirectionRtl: Boolean? = null): Boolean =
  firstStrongTextDirectionIsRtl(text) ?: emptyDirectionRtl ?: localeTextDirectionIsRtl()

/** Optional IME language hint for an empty new editor, not a content direction. */
internal fun inputLanguageDirectionHint(languageTag: String?): Boolean? {
  val tag = languageTag?.trim()?.replace('_', '-')?.takeIf { it.isNotEmpty() } ?: return null
  val locale = Locale.forLanguageTag(tag)
  if (locale.language.isEmpty() || locale.language == "und") return null
  return try {
    android.text.TextUtils.getLayoutDirectionFromLocale(locale) == android.view.View.LAYOUT_DIRECTION_RTL
  } catch (_: RuntimeException) {
    locale.language in setOf("ar", "fa", "he", "iw", "ur", "ps", "sd", "ug", "yi")
  }
}

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

  /** First-strong direction with the user's locale as the empty-text fallback. */
  fun directionHeuristic(text: CharSequence): TextDirectionHeuristic {
    return if (textIsRtl(text)) TextDirectionHeuristics.FIRSTSTRONG_RTL
    else TextDirectionHeuristics.FIRSTSTRONG_LTR
  }

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
  fun measureWrapped(text: String, fontSize: Double, width: Double): TextIntrinsicSize {
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
      .setTextDirection(directionHeuristic(text))
      .build()
    return TextIntrinsicSize(width, max(layout.height.toDouble(), measure(text, fontSize).height))
  }

  fun createLayout(annotation: TextAnnotation): StaticLayout {
    val paint = createPaint(annotation.fontSize, annotation.textColor)
    val measuredWidth = measure(annotation.text, annotation.fontSize).width
    val width = max(1, ceil(max(annotation.intrinsicWidth, measuredWidth)).toInt())
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
      .setTextDirection(directionHeuristic(annotation.text))
      .build()
  }

  fun configureEditor(
    editor: TextView,
    fontSize: Double,
    text: CharSequence = editor.text ?: "",
    emptyDirectionRtl: Boolean? = null,
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
    configureEditorDirection(editor, text, emptyDirectionRtl)
    editor.setPadding(
      horizontalPaddingPx,
      verticalPaddingPx,
      horizontalPaddingPx,
      verticalPaddingPx,
    )
  }

  fun configureEditorDirection(
    editor: TextView,
    text: CharSequence,
    emptyDirectionRtl: Boolean? = null,
  ) {
    val direction = if (firstStrongTextDirectionIsRtl(text) != null) {
      TextView.TEXT_DIRECTION_FIRST_STRONG
    } else if (textDirectionIsRtl(text, emptyDirectionRtl)) {
      TextView.TEXT_DIRECTION_RTL
    } else {
      TextView.TEXT_DIRECTION_LTR
    }
    if (editor.textDirection != direction) editor.textDirection = direction
    val gravity = android.view.Gravity.TOP or if (textDirectionIsRtl(text, emptyDirectionRtl)) {
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
  )

  fun draw(canvas: android.graphics.Canvas, excludedAnnotationId: String? = null) {
    entries.forEach { entry ->
      if (entry.annotation.id == excludedAnnotationId) return@forEach
      canvas.save()
      canvas.translate(
        entry.annotation.position.x.toFloat(),
        entry.annotation.position.y.toFloat(),
      )
      entry.layout.draw(canvas)
      canvas.restore()
    }
  }

  companion object {
    fun empty(): TextRenderLayer = TextRenderLayer(emptyList())

    fun from(annotations: List<TextAnnotation>): TextRenderLayer {
      return TextRenderLayer(
        annotations.map { annotation ->
          Entry(annotation, TextLayoutSpec.createLayout(annotation))
        }.toList(),
      )
    }
  }
}
