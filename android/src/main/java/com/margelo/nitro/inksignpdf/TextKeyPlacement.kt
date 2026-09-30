package com.margelo.nitro.inksignpdf

import com.margelo.nitro.inksignpdf.TextKeyOccurrence.FIRST
import com.margelo.nitro.inksignpdf.TextKeyOccurrence.LAST
import kotlin.math.abs

internal data class PdfiumTextKeyPlacement(
  val match: PdfiumTextKeyMatch,
  val rule: PdfiumHorizontalSnapCandidate,
  val contentLeft: Double,
  val contentRight: Double,
)

internal const val keyInsertionLabelMarginPoints = 2.0

internal fun selectPdfiumTextKeyPlacement(
  matches: List<PdfiumTextKeyMatch>,
  rules: List<PdfiumHorizontalSnapCandidate>,
  occurrence: TextKeyOccurrence,
  directionRtl: Boolean,
  page: PdfPageDimensions,
): PdfiumTextKeyPlacement? {
  data class RuleFit(
    val rule: PdfiumHorizontalSnapCandidate,
    val contentLeft: Double,
    val contentRight: Double,
    val horizontalGap: Double,
    val verticalGap: Double,
  )

  val orderedMatches = matches.sortedWith(
    compareBy<PdfiumTextKeyMatch> { it.top }.thenBy { it.left }.thenBy { it.sourceIndex },
  )
  val matchOrder = when (occurrence) {
    FIRST -> orderedMatches.indices
    LAST -> orderedMatches.indices.reversed()
  }
  for (matchIndex in matchOrder) {
    val match = orderedMatches[matchIndex]
    val centerY = match.lineCenter
    if (!match.lineHeight.isFinite() || match.lineHeight <= 0.0 || !centerY.isFinite()) continue

    var bestFit: RuleFit? = null
    for (candidate in rules) {
      if (!candidate.left.isFinite() || !candidate.right.isFinite() || !candidate.y.isFinite() ||
        candidate.left < 0.0 || candidate.right > page.width || candidate.right <= candidate.left ||
        candidate.y !in 0.0..page.height) continue

      val overlapsLabel = if (directionRtl) candidate.right > match.left else candidate.left < match.right
      val contentLeft = if (directionRtl || !overlapsLabel) candidate.left
        else match.right + keyInsertionLabelMarginPoints
      val contentRight = if (!directionRtl || !overlapsLabel) candidate.right
        else match.left - keyInsertionLabelMarginPoints
      val isOnDirectionSide = if (directionRtl) candidate.left < match.left else candidate.right > match.right
      val horizontalGap = if (directionRtl) match.left - contentRight else contentLeft - match.right
      val verticalGap = abs(candidate.y - centerY)
      if (!isOnDirectionSide || contentRight <= contentLeft || horizontalGap < 0.0 ||
        verticalGap > match.lineHeight) continue

      val current = bestFit
      val isBetter = when {
        current == null -> true
        horizontalGap != current.horizontalGap -> horizontalGap < current.horizontalGap
        verticalGap != current.verticalGap -> verticalGap < current.verticalGap
        candidate.left != current.rule.left -> candidate.left < current.rule.left
        else -> candidate.y < current.rule.y
      }
      if (isBetter) bestFit = RuleFit(candidate, contentLeft, contentRight, horizontalGap, verticalGap)
    }
    bestFit?.let { return PdfiumTextKeyPlacement(match, it.rule, it.contentLeft, it.contentRight) }
  }
  return null
}
