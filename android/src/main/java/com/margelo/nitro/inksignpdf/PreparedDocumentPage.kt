package com.margelo.nitro.inksignpdf

internal interface TextPageContext {
  val generation: Long
  val pageId: String
}

internal data class DocumentPageContext(
  override val generation: Long,
  override val pageId: String,
) : TextPageContext

internal class PreparedPageContext(
  override val generation: Long,
  override val pageId: String,
  sourceAnalysis: PdfiumPreparedPageAnalysis,
  sourceDimensions: PdfPageDimensions = PdfPageDimensions(sourceAnalysis.width, sourceAnalysis.height),
) : TextPageContext {
  val sourceToCanonical = PageCoordinates(sourceDimensions).displayToRawTransform()
  val analysis = CanonicalPreparedPageAnalysis(
    sourceAnalysis.glyphs.map { glyph ->
      glyph.copy(bounds = glyph.bounds?.let { canonicalMatch(it, sourceToCanonical) })
    },
    sourceAnalysis.rules.mapIndexed { index, rule ->
      CanonicalWritingRule(sourceToCanonical.map(PagePoint(rule.left, rule.y)).toPagePoint(),
        sourceToCanonical.map(PagePoint(rule.right, rule.y)).toPagePoint(), index)
    },
  )
  val labels: List<PreparedTextLabel> = preparedTextLabels(sourceAnalysis).map {
    it.copy(match = canonicalMatch(it.match, sourceToCanonical))
  }
}

internal data class CanonicalWritingRule(val start: PagePoint, val end: PagePoint, val sourceIndex: Int)
internal data class CanonicalPreparedPageAnalysis(
  val glyphs: List<PdfiumPreparedGlyph>,
  val rules: List<CanonicalWritingRule>,
)

private fun canonicalMatch(match: PdfiumTextKeyMatch, transform: PageTransform): PdfiumTextKeyMatch {
  val bounds = textAnnotationOuterBounds(PageRect(match.left, match.top, match.right, match.bottom), transform, 0.0, 0.0)
  val rowStart = transform.map(match.rowStart).toPagePoint()
  val rowEnd = transform.map(match.rowEnd).toPagePoint()
  return match.copy(left = bounds.left, top = bounds.top, right = bounds.right, bottom = bounds.bottom,
    lineCenter = (rowStart.y + rowEnd.y) / 2.0, lineHeight = kotlin.math.abs(rowEnd.y - rowStart.y),
    rowStart = rowStart, rowEnd = rowEnd)
}

private fun ViewPoint.toPagePoint() = PagePoint(x, y)
