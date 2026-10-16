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
  fun initialSourcesLoadBeforePageCommandsAndRemainClean() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = HybridInkSignDocument(instrumentation.targetContext)
    try {
      instrumentation.runOnMainSync {
        document.core.initialize(DocumentOptions(type = null, recordHistory = null, tag = "initial",
          imagePageSize = null, targetDpi = null, jpegQuality = null, androidFallbackFont = null,
          sources = arrayOf(source.path)))
      }
      val page = await { document.getPage(PageQuery.create(0.0)) }
      instrumentation.runOnMainSync {
        assertEquals("initial", page.getState().tag)
        assertEquals(1.0, document.pageCount, 0.0)
        assertTrue(!document.getState().isDirty)
      }
    } finally {
      await { document.close() }
      source.delete()
    }
  }

  @Test
  fun initialSourceFailureReachesViewerAndQueuedReadWhileCloseStillWorks() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val document = HybridInkSignDocument(instrumentation.targetContext)
    var view: HybridInkSignView? = null
    var reportedError: String? = null
    try {
      instrumentation.runOnMainSync {
        view = viewer().also {
          it.document = document
          it.onStateChange = { state -> reportedError = state.error?.asSecondOrNull() }
        }
        document.core.initialize(DocumentOptions(type = null, recordHistory = null, tag = null,
          imagePageSize = null, targetDpi = null, jpegQuality = null, androidFallbackFont = null,
          sources = arrayOf(File(instrumentation.targetContext.cacheDir, "missing-${java.util.UUID.randomUUID()}.pdf").path)))
      }
      val failure = runCatching { await { document.getPage(PageQuery.create(0.0)) } }.exceptionOrNull()
      instrumentation.runOnMainSync {
        assertTrue(failure != null)
        assertEquals(document.core.initializationError?.message, failure?.message)
        assertEquals(failure?.message, reportedError)
        assertTrue(view!!.document === document)
      }
    } finally {
      instrumentation.runOnMainSync { view?.onDropView() }
      await { document.close() }
    }
  }

  @Test
  fun emptyDocumentPopulatesAnAttachedViewerAndSurvivesDetach() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = HybridInkSignDocument(instrumentation.targetContext)
    var view: HybridInkSignView? = null
    val events = mutableListOf<PageChangeEvent>()
    try {
      instrumentation.runOnMainSync {
        view = viewer().also {
          it.document = document
          it.onPageChange = { page -> events.add(page) }
        }
        assertEquals(0.0, document.pageCount, 0.0)
        assertTrue(events.isEmpty())
      }
      val unchanged = await { document.addPages(DocumentAddPagesOptions(
        type = null, tag = null, sources = emptyArray(), imagePageSize = null,
        targetDpi = null, jpegQuality = null)) }
      assertEquals(0.0, unchanged.addedPageCount, 0.0)
      val added = await { document.addPages(DocumentAddPagesOptions(
        type = null, tag = "first", sources = arrayOf(source.path), imagePageSize = null,
        targetDpi = null, jpegQuality = null)) }
      instrumentation.runOnMainSync {
        assertEquals(1.0, added.pageCount, 0.0)
        assertEquals(document.core.state.pageInfo(0).pageId, events.last().pageId)
        assertTrue(document.getState().isDirty)
        assertTrue(view!!.document === document)
        view!!.document = null
        assertEquals(1.0, document.pageCount, 0.0)
      }
    } finally {
      instrumentation.runOnMainSync { view?.onDropView() }
      await { document.close() }
      source.delete()
    }
  }

  @Test
  fun pageCallbackRegisteredAfterAttachmentReceivesCurrentSnapshot() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = await { HybridInkSignDocument(instrumentation.targetContext).initializeSource(source.path) }
    var view: HybridInkSignView? = null
    try {
      instrumentation.runOnMainSync {
        val attached = viewer()
        view = attached
        attached.document = document
        attached.onStateChange = {}
        val events = mutableListOf<PageChangeEvent>()
        attached.onPageChange = { events.add(it) }
        assertEquals(1, events.size)
        assertEquals(300.0, events.single().width, 0.0)
        assertEquals(400.0, events.single().height, 0.0)
        attached.onStateChange = {}
        assertEquals("Unchanged snapshots remain suppressed", 1, events.size)
        val replacementEvents = mutableListOf<PageChangeEvent>()
        attached.onPageChange = { replacementEvents.add(it) }
        assertEquals(events, replacementEvents)
      }
    } finally {
      instrumentation.runOnMainSync { view?.onDropView() }
      await { document.close() }
      source.delete()
    }
  }

  @Test
  fun documentSurvivesDetachAndViewerDisposalThenReattaches() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    var document: HybridInkSignDocumentSpec? = null
    var first: HybridInkSignView? = null
    var second: HybridInkSignView? = null
    try {
      val owned = await { HybridInkSignDocument(instrumentation.targetContext).initializeSource(source.path) }
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
    val document = await { HybridInkSignDocument(instrumentation.targetContext).initializeSource(source.path) }
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
