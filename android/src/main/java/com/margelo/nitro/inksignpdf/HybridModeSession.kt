package com.margelo.nitro.inksignpdf

import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.Promise
import java.lang.ref.WeakReference

/** View-owned lifetime; prepared handles share the token, not document ownership. */
internal class ModeSessionToken(
  val generation: Long,
  val mode: InputMode,
  val textOptions: TextModeOptions? = null,
) {
  var cancelled = false
}

@DoNotStrip
internal class HybridModeSession(owner: HybridInkSignView, private val token: ModeSessionToken) : HybridModeSessionSpec() {
  private val owner = WeakReference(owner)

  override fun getPage(pageIndex: Double?): Promise<HybridAnalyzedPageSpec> =
    withOwner { it.getSessionPage(token, pageIndex) }

  override fun requestPageCoords(): Promise<PageCoords> =
    withOwner { it.requestSessionPageCoords(token) }

  override fun setViewport(options: ViewportOptions?): Promise<Unit> =
    withOwner { it.setSessionViewport(token, options) }

  private inline fun <T> withOwner(action: (HybridInkSignView) -> T): T =
    owner.get()?.let(action) ?: throw PdfSessionException("operation_cancelled", "The mode session view was disposed")
}
