package com.margelo.nitro.inksignpdf

import android.app.Instrumentation
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertTrue

internal fun awaitPreparedPage(
  instrumentation: Instrumentation,
  view: HybridInkSignView,
  pageIndex: Double? = null,
  tag: String? = null,
): HybridAnalyzedPageSpec {
  val settled = CountDownLatch(1)
  val page = AtomicReference<HybridAnalyzedPageSpec>()
  val failure = AtomicReference<Throwable>()
  instrumentation.runOnMainSync {
    val query = if (tag != null) Variant_Double_TaggedPageQuery.create(TaggedPageQuery(tag, pageIndex))
      else pageIndex?.let(Variant_Double_TaggedPageQuery::create)
    view.getPage(query).then { page.set(it); settled.countDown() }
      .catch { error -> failure.set(error); settled.countDown() }
  }
  assertTrue("getPage did not settle", settled.await(15L, TimeUnit.SECONDS))
  failure.get()?.let { throw AssertionError("getPage failed", it) }
  return checkNotNull(page.get())
}

internal fun resolveFreeTextTarget(page: HybridAnalyzedPageSpec, bounds: TextAnnotationBounds): Double =
  page.resolveText(
    ResolveTextOptions(font = null,
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
  page: HybridAnalyzedPageSpec,
  bounds: TextAnnotationBounds,
  value: String,
): Double {
  val id = resolveFreeTextTarget(page, bounds)
  page.setTextValue(id, value, null)
  return id
}
