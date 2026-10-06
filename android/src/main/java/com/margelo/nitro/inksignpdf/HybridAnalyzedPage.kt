package com.margelo.nitro.inksignpdf

import com.facebook.proguard.annotations.DoNotStrip
import java.lang.ref.WeakReference

internal class PreparedPageContext(
  val generation: Long,
  val pageId: String,
  val geometryRevision: Long,
  val pageIndexAtPreparation: Int,
  sourceAnalysis: PdfiumPreparedPageAnalysis,
  sourceDimensions: PdfPageDimensions = PdfPageDimensions(sourceAnalysis.width, sourceAnalysis.height),
) {
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

/** Prepared page handle that retains detached analysis without retaining its view. */
@DoNotStrip
internal class HybridAnalyzedPage(
  owner: HybridInkSignView,
  private val context: PreparedPageContext,
) : HybridAnalyzedPageSpec() {
  private val owner = WeakReference(owner)

  override fun resolveText(options: ResolveTextOptions): Double =
    withOwner { it.resolvePreparedText(context, options) }

  override fun getTextValue(id: Double): String =
    withOwner { it.readPreparedTextValue(context, id) }

  override fun adjustTextSize(id: Double, delta: Double): Double =
    withOwner { it.adjustPreparedTextSize(context, id, delta) }

  override fun setTextValue(id: Double, text: String) {
    withOwner { it.setPreparedTextValue(context, id, text) }
  }

  override fun clearText(id: Double) {
    withOwner { it.clearPreparedText(context, id) }
  }

  override fun setTextOptions(id: Double, options: TextAnnotationOptions) {
    withOwner { it.setPreparedTextOptions(context, id, options) }
  }

  override fun getTextEntry(id: Double): TextEntry =
    withOwner { it.preparedTextEntry(context, id) }

  override fun getTextEntries(): Array<TextEntry> =
    withOwner { it.preparedTextEntries(context) }

  override fun focusText(id: Double, options: FieldFocusOptions?): com.margelo.nitro.core.Promise<Unit> =
    withOwner { it.focusPreparedText(context, id, options) }

  private inline fun <T> withOwner(action: (HybridInkSignView) -> T): T =
    owner.get()?.let(action) ?: throw PdfSessionException(
      "operation_cancelled", "The prepared page view has been disposed",
    )
}
