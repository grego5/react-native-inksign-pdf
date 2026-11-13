package com.margelo.nitro.inksignpdf

import android.app.Instrumentation
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertTrue

private fun InputTargetResolutionOptions.underlineOptions() = ResolveInputUnderlineOptions(
  checkNotNull(fieldName), bounds, occurrence, font, fontSize, color, direction, maxLines, alignment, verticalAnchor,
)

private fun InputTargetResolutionOptions.areaOptions() = CreateInputAreaOptions(
  checkNotNull(bounds), font, fontSize, color, direction, maxLines, alignment, verticalAnchor,
)

internal fun HybridDocumentPageSpec.resolveInputTarget(options: InputTargetResolutionOptions): Double =
  if (options.fieldName != null) resolveInputUnderline(options.underlineOptions()) else createInputArea(options.areaOptions())

internal fun awaitPreparedPage(
  instrumentation: Instrumentation,
  view: HybridInkSignView,
  pageIndex: Double? = null,
  tag: String? = null,
): HybridDocumentPageSpec {
  val settled = CountDownLatch(1)
  val page = AtomicReference<HybridDocumentPageSpec>()
  val failure = AtomicReference<Throwable>()
  instrumentation.runOnMainSync {
    val query = if (tag != null) PageQuery.create(TaggedPageQuery(tag, pageIndex))
      else PageQuery.create(pageIndex ?: 0.0)
    (checkNotNull(view.document) { "Viewer test must attach a document before preparing a page" } as Variant_HybridInkSignDocumentSpec_DocumentOptions.First)
      .value.getPage(query).then { page.set(it); settled.countDown() }
      .catch { error -> failure.set(error); settled.countDown() }
  }
  assertTrue("Document getPage did not settle", settled.await(15L, TimeUnit.SECONDS))
  failure.get()?.let { throw AssertionError("Document getPage failed", it) }
  return checkNotNull(page.get())
}

internal fun resolveFreeTextTarget(page: HybridDocumentPageSpec, bounds: TextAnnotationBounds): Double =
  page.resolveInputTarget(
    InputTargetResolutionOptions(font = null,
      fieldName = null,
      bounds = bounds,
      occurrence = null,
      fontSize = null,
      color = null,
      direction = null,
      maxLines = null,
      alignment = null,
      verticalAnchor = null,
    ),
  )

internal fun setPreparedText(
  page: HybridDocumentPageSpec,
  bounds: TextAnnotationBounds,
  value: String,
  options: TextAnnotationOptions? = null,
): Double {
  val id = resolveFreeTextTarget(page, bounds)
  page.setTextValue(id, value, options)
  return id
}
