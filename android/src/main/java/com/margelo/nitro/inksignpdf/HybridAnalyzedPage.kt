package com.margelo.nitro.inksignpdf

import com.facebook.proguard.annotations.DoNotStrip
import java.lang.ref.WeakReference

internal data class PreparedPageContext(
  val generation: Long,
  val pageId: String,
  val geometryRevision: Long,
  val pageIndexAtPreparation: Int,
  val analysis: PdfiumPreparedPageAnalysis,
) {
  val labels: List<PreparedTextLabel> = preparedTextLabels(analysis)
}

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
