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
  private val core = owner.core

  override fun getValue(): String = core.text.getValue(this, textId)
  override fun setValue(text: String, options: TextAnnotationOptions?) = core.text.setValue(this, textId, text, options)
  override fun setOptions(options: TextAnnotationOptions) = core.text.setOptions(this, textId, options)
  override fun adjustSize(delta: Double): Double = core.text.adjustSize(this, textId, delta)
}