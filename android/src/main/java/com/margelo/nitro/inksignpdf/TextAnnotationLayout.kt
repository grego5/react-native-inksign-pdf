package com.margelo.nitro.inksignpdf

import kotlin.math.max

/** Shared immutable layout for committed values and interactive drafts. */
internal object TextAnnotationLayout {
  fun reflow(annotation: TextAnnotation, page: PdfPageDimensions,
             intrinsicSize: TextIntrinsicSize? = null): TextAnnotation {
    annotation.flowBounds?.let { flow ->
      return annotation.copy(bounds = TextLayoutSpec.visibleBounds(annotation, flow))
    }
    val size = intrinsicSize ?: textEditorIntrinsicSize(annotation.text, annotation.fontSize,
      annotation.font?.typeface ?: TextLayoutSpec.typeface)
    val position = clampTextAnnotationPosition(annotation.position, size, page)
    return annotation.copy(bounds = PageRect(position.x, position.y, position.x + size.width, position.y + size.height))
  }

  fun resize(annotation: TextAnnotation, fontSize: Double, page: PdfPageDimensions): TextAnnotation =
    reflow(annotation.copy(fontSize = fontSize), page)
}

internal const val defaultTextFontSize = 16.0
internal const val minimumTextFontSize = 8.0
internal const val maximumTextFontSize = 72.0
internal const val minimumTextEditorWidthEm = 1.0

internal fun textEditorMinimumContentWidth(fontSize: Double): Double =
  fontSize * minimumTextEditorWidthEm

internal fun normalizeTextFontSize(value: Double?): Double =
  value
    ?.takeIf { it.isFinite() && it > 0.0 }
    ?.coerceIn(minimumTextFontSize, maximumTextFontSize)
    ?: defaultTextFontSize

internal fun clampTextAnnotationPosition(
  position: PagePoint,
  size: TextIntrinsicSize,
  page: PdfPageDimensions,
): PagePoint {
  val x = if (size.width > page.width) {
    (page.width - size.width) / 2.0
  } else {
    position.x.coerceIn(0.0, page.width - size.width)
  }
  val y = if (size.height > page.height) {
    (page.height - size.height) / 2.0
  } else {
    position.y.coerceIn(0.0, page.height - size.height)
  }
  return PagePoint(x, y)
}

internal fun programmaticTextFlowBounds(
  bounds: TextAnnotationBounds,
  page: PdfPageDimensions,
): PageRect {
  val right = bounds.x + bounds.width
  val bottom = bounds.y + bounds.height
  val valid = bounds.x.isFinite() && bounds.y.isFinite() &&
    bounds.width.isFinite() && bounds.height.isFinite() &&
    bounds.width > 0.0 && bounds.height > 0.0 &&
    right.isFinite() && bottom.isFinite() &&
    bounds.x >= 0.0 && bounds.y >= 0.0 &&
    right <= page.width && bottom <= page.height
  if (!valid) {
    throw PdfSessionException(
      "invalid_text_bounds",
      "Text bounds must define an ordered rectangle inside the active page",
    )
  }
  return PageRect(
    left = bounds.x,
    top = bounds.y,
    right = right,
    bottom = bottom,
  )
}

internal fun textEditorIntrinsicSize(text: String, fontSize: Double, typeface: android.graphics.Typeface = TextLayoutSpec.typeface): TextIntrinsicSize {
  val measured = TextLayoutSpec.measure(text, fontSize, typeface)
  return measured.copy(width = max(measured.width, textEditorMinimumContentWidth(fontSize)))
}


internal fun textAnnotationOuterBounds(
  bounds: PageRect,
  transform: PageTransform,
  horizontalPaddingPx: Double,
  verticalPaddingPx: Double,
): PageRect {
  val corners = listOf(
    transform.map(PagePoint(bounds.left, bounds.top)),
    transform.map(PagePoint(bounds.right, bounds.top)),
    transform.map(PagePoint(bounds.left, bounds.bottom)),
    transform.map(PagePoint(bounds.right, bounds.bottom)),
  )
  return PageRect(
    corners.minOf { it.x } - horizontalPaddingPx,
    corners.minOf { it.y } - verticalPaddingPx,
    corners.maxOf { it.x } + horizontalPaddingPx,
    corners.maxOf { it.y } + verticalPaddingPx,
  )
}
