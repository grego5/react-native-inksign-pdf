package com.margelo.nitro.inksignpdf

import com.facebook.proguard.annotations.DoNotStrip
import java.lang.ref.WeakReference

/** Prepared page handle that retains detached analysis without retaining its view. */
@DoNotStrip
internal class HybridAnalyzedPage(
  owner: HybridInkSignView,
  context: PreparedPageContext,
  private val modeSession: ModeSessionToken? = null,
) : HybridAnalyzedPageSpec() {
  private val owner = WeakReference(owner)
  private val prepared = WeakReference(context)
  private val context: PreparedPageContext get() = prepared.get()
    ?: throw PdfSessionException("operation_cancelled", "The prepared page was released")

  override fun getState(): PageInfo = withOwner { it.core.pageInfo(context) }

  override fun resolveText(options: ResolveTextOptions): Double =
    withOwner { it.resolvePreparedText(context, options) }

  override fun getTextValue(id: Double): String =
    withOwner { it.readPreparedTextValue(context, id) }

  override fun adjustTextSize(id: Double, delta: Double): Double =
    withOwner { it.adjustPreparedTextSize(context, id, delta) }

  override fun setTextValue(id: Double, text: String, options: TextAnnotationOptions?) {
    withOwner { it.setPreparedTextValue(context, id, text, options) }
  }

  override fun setTextOptions(id: Double, options: TextAnnotationOptions) {
    withOwner { it.setPreparedTextOptions(context, id, options) }
  }

  override fun getTextEntry(id: Double): TextEntry =
    withOwner { it.preparedTextEntry(context, id) }

  override fun getTextEntries(): Array<TextEntry> =
    withOwner { it.preparedTextEntries(context) }

  override fun focusText(id: Double, options: TextFocusOptions?): com.margelo.nitro.core.Promise<Unit> =
    withOwner { it.focusPreparedText(context, id, options, modeSession) }

  private fun <T> withOwner(action: (HybridInkSignView) -> T): T =
    owner.get()?.let { view -> view.withModeSession(modeSession) { action(view) } } ?: throw PdfSessionException(
      "operation_cancelled", "The prepared page view has been disposed",
    )
}
