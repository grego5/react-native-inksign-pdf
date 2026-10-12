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
) : TextPageContext {
  val analysis = CanonicalPreparedPageAnalysis(
    sourceAnalysis.glyphs,
    sourceAnalysis.rules.mapIndexed { index, rule ->
      CanonicalWritingRule(rule.start, rule.end, index)
    },
  )
  val labels: List<PreparedTextLabel> = preparedTextLabels(sourceAnalysis)
  private val orientations = HashMap<Int, ProjectedPreparedPage>()

  fun projected(page: PdfPageDimensions): ProjectedPreparedPage = orientations.getOrPut(page.rotation) {
    val transform = PageCoordinates(page).canonicalToDisplayTransform()
    ProjectedPreparedPage(
      labels.map { it.copy(match = projectedMatch(it.match, transform)) },
      analysis.rules.mapNotNull { rule ->
        val start = transform.map(rule.start)
        val end = transform.map(rule.end)
        if (kotlin.math.abs(start.y - end.y) > 0.001) null else
          rule to PdfiumHorizontalSnapCandidate(minOf(start.x, end.x), maxOf(start.x, end.x), start.y)
      },
      page,
    )
  }
}

internal data class ProjectedPreparedPage(
  val labels: List<PreparedTextLabel>,
  val rules: List<Pair<CanonicalWritingRule, PdfiumHorizontalSnapCandidate>>,
  private val page: PdfPageDimensions,
) {
  private data class CachedPair(val placement: PdfiumTextKeyPlacement?)
  private val pairings = HashMap<Pair<String, Boolean?>, CachedPair>()

  fun selectPair(candidates: List<PreparedTextLabel>, occurrence: TextKeyOccurrence,
                 directionRtl: Boolean?): PdfiumTextKeyPlacement? {
    val ordered = candidates.sortedWith(compareBy<PreparedTextLabel> { it.match.top }
      .thenBy { it.match.left }.thenBy { it.match.sourceIndex })
    val sequence = if (occurrence == TextKeyOccurrence.LAST) ordered.asReversed() else ordered
    return sequence.firstNotNullOfOrNull { label ->
      pairings.getOrPut(label.identity to directionRtl) {
        CachedPair(selectPdfiumTextKeyPlacement(listOf(label.match), rules.map { it.second },
          TextKeyOccurrence.FIRST, directionRtl, page))
      }.placement
    }
  }
}

internal data class CanonicalWritingRule(val start: PagePoint, val end: PagePoint, val sourceIndex: Int)
internal data class CanonicalPreparedPageAnalysis(
  val glyphs: List<PdfiumPreparedGlyph>,
  val rules: List<CanonicalWritingRule>,
)

private fun projectedMatch(match: PdfiumTextKeyMatch, transform: PageTransform): PdfiumTextKeyMatch {
  val bounds = textAnnotationOuterBounds(PageRect(match.left, match.top, match.right, match.bottom), transform, 0.0, 0.0)
  val rowStart = transform.map(match.rowStart).toPagePoint()
  val rowEnd = transform.map(match.rowEnd).toPagePoint()
  return match.copy(left = bounds.left, top = bounds.top, right = bounds.right, bottom = bounds.bottom,
    lineCenter = (rowStart.y + rowEnd.y) / 2.0, lineHeight = kotlin.math.hypot(rowEnd.x - rowStart.x, rowEnd.y - rowStart.y),
    rowStart = rowStart, rowEnd = rowEnd)
}

private fun ViewPoint.toPagePoint() = PagePoint(x, y)
