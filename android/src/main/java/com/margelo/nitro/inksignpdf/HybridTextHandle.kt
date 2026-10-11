package com.margelo.nitro.inksignpdf

import com.facebook.proguard.annotations.DoNotStrip
import java.lang.ref.WeakReference

/** Binds one text target without retaining page analysis or the owning view. */
@DoNotStrip
internal class HybridTextHandle(
  owner: InkSignDocumentOwner,
  override val generation: Long,
  override val pageId: String,
  private val textId: Double,
) : HybridTextHandleSpec(), TextPageContext {
  private val owner = WeakReference(owner)
  override val modeSession: ModeSessionToken? get() = null

  override fun getValue(): String = withOwner { it.readPreparedTextValue(this, textId) }

  override fun setValue(text: String, options: TextAnnotationOptions?) {
    withOwner { it.setPreparedTextValue(this, textId, text, options) }
  }

  override fun setOptions(options: TextAnnotationOptions) {
    withOwner { it.setPreparedTextOptions(this, textId, options) }
  }

  override fun adjustSize(delta: Double): Double =
    withOwner { it.adjustPreparedTextSize(this, textId, delta) }

  private inline fun <T> withOwner(action: (InkSignDocumentOwner) -> T): T =
    owner.get()?.let(action) ?: throw PdfSessionException(
      "operation_cancelled", "The text handle view has been disposed",
    )
}
