package com.margelo.nitro.inksignpdf

import android.graphics.pdf.PdfDocument
import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.margelo.nitro.core.Promise
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class DocumentAttachmentTest {
  @Test
  fun documentSurvivesDetachAndViewerDisposalThenReattaches() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    var document: HybridInkSignDocumentSpec? = null
    var first: HybridInkSignView? = null
    var second: HybridInkSignView? = null
    try {
      val owned = await { HybridInkSignDocument(instrumentation.targetContext).open(source.path, null) }
      document = owned
      val page = await { owned.getPage(PageQuery.create(0.0)) }
      var pageId = ""
      instrumentation.runOnMainSync {
        pageId = page.getState().pageId
        first = viewer()
        first!!.document = owned
        assertTrue(first!!.document === owned)
        first!!.document = null
        first!!.onDropView()
      }
      await { owned.rotatePage(0.0, 90.0) }
      instrumentation.runOnMainSync {
        assertEquals(pageId, page.getState().pageId)
        assertEquals(90.0, page.getState().rotation, 0.0)
        second = viewer()
        second!!.document = owned
        assertTrue(second!!.document === owned)
      }
      await { owned.close() }
      instrumentation.runOnMainSync { assertNull(second!!.document) }
    } finally {
      instrumentation.runOnMainSync {
        first?.onDropView()
        second?.onDropView()
      }
      document?.let { await { it.close() } }
      source.delete()
    }
  }

  @Test
  fun documentAllowsOneViewerAndReleasesTheAttachmentOnDetach() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = await { HybridInkSignDocument(instrumentation.targetContext).open(source.path, null) }
    var first: HybridInkSignView? = null
    var second: HybridInkSignView? = null
    try {
      instrumentation.runOnMainSync {
        first = viewer()
        second = viewer()
        first!!.document = document
        second!!.document = document
        assertTrue(first!!.document === document)
        assertNull(second!!.document)
        first!!.document = null
        second!!.document = document
        assertTrue(second!!.document === document)
      }
    } finally {
      instrumentation.runOnMainSync {
        first?.onDropView()
        second?.onDropView()
      }
      await { document.close() }
      source.delete()
    }
  }

  private fun viewer(): HybridInkSignView {
    val view = HybridInkSignView(InstrumentationRegistry.getInstrumentation().targetContext)
    view.view.measure(View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY),
      View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY))
    view.view.layout(0, 0, 600, 800)
    return view
  }

  private fun source(): File {
    val source = File.createTempFile("attachment-", ".pdf",
      InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)
    val pdf = PdfDocument()
    try {
      val page = pdf.startPage(PdfDocument.PageInfo.Builder(300, 400, 1).create())
      pdf.finishPage(page)
      source.outputStream().use { pdf.writeTo(it) }
    } finally { pdf.close() }
    return source
  }

  private fun <T : Any> await(request: () -> Promise<T>): T {
    val completed = CountDownLatch(1)
    val result = AtomicReference<T>()
    val failure = AtomicReference<Throwable>()
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
      request().then { result.set(it); completed.countDown() }
        .catch { failure.set(it); completed.countDown() }
    }
    assertTrue("Native command must settle", completed.await(120, TimeUnit.SECONDS))
    failure.get()?.let { throw it }
    return checkNotNull(result.get())
  }
}
