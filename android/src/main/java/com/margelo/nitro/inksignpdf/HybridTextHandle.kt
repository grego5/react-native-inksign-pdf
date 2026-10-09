package com.margelo.nitro.inksignpdf

import com.facebook.proguard.annotations.DoNotStrip
import java.lang.ref.WeakReference

/** Binds one text target without retaining page analysis or the owning view. */
@DoNotStrip
internal class HybridTextHandle(
  owner: HybridInkSignView,
  override val generation: Long,
  override val pageId: String,
  private val textId: Double,
) : HybridTextHandleSpec(), TextPageContext {
  private val owner = WeakReference(owner)
  override val modeSession: ModeSessionToken? get() = null

  override fun getValue(): String = withOwner { it.readPreparedTextValue(this, textId) }

  override fun setValue(text: String) {
    withOwner { it.setPreparedTextValue(this, textId, text) }
  }

  override fun setOptions(options: TextAnnotationOptions) {
    withOwner { it.setPreparedTextOptions(this, textId, options) }
  }

  override fun adjustSize(delta: Double): Double =
    withOwner { it.adjustPreparedTextSize(this, textId, delta) }

  private inline fun <T> withOwner(action: (HybridInkSignView) -> T): T =
    owner.get()?.let(action) ?: throw PdfSessionException(
      "operation_cancelled", "The text handle view has been disposed",
    )
}
