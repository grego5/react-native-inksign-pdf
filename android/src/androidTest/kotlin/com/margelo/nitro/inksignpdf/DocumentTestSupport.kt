package com.margelo.nitro.inksignpdf

import com.margelo.nitro.core.Promise

/** Fixture completion uses the same initialization command as the public factory. */
internal fun HybridInkSignDocument.initializeSource(
  source: String,
  options: DocumentOptions? = null,
): Promise<HybridInkSignDocumentSpec> {
  val initial = options?.copy(sources = arrayOf(source)) ?: DocumentOptions(
    type = null, recordHistory = null, tag = null, imagePageSize = null,
    targetDpi = null, jpegQuality = null, androidFallbackFont = null, sources = arrayOf(source))
  val loading = core.initialize(initial)
  return Promise.async { loading.await(); this@initializeSource }
}
