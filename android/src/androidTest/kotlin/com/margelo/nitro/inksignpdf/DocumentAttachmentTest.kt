package com.margelo.nitro.inksignpdf

import android.graphics.pdf.PdfDocument
import android.view.MotionEvent
import android.widget.EditText
import android.widget.FrameLayout
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
  fun targetReadersFollowMoveRestorationAndDeletedTargetReuse() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = HybridInkSignDocument(instrumentation.targetContext)
    try {
      await { document.addPages(DocumentAddPagesOptions(type = null, tag = null,
        sources = arrayOf(source.path), imagePageSize = null, targetDpi = null, jpegQuality = null)) }
      val handle = await { document.getPage(PageQuery.create(0.0)) } as HybridDocumentPage
      lateinit var baseline: TextAnnotation
      instrumentation.runOnMainSync {
        baseline = document.core.text.insert(handle.context,
          TextAnnotationBounds(24.0, 40.0, 100.0, 60.0), "Original", null)
      }
      await { document.acceptChanges() }
      instrumentation.runOnMainSync {
        val core = document.core
        val page = checkNotNull(core.coordinator.pageForId(handle.context.pageId))
        val slot = checkNotNull(core.coordinator.textTarget(baseline.id))
        fun checkReaders(expected: TextAnnotation) {
          assertEquals(expected, slot.state.annotation)
          assertEquals(listOf(PageContent.Text(expected)), page.history.contentSnapshot())
          assertEquals(expected.canonicalPlacementBounds, slot.canonicalBounds)
          val entry = core.text.getEntry(handle.context, baseline.id.toDouble())
          assertEquals(expected.text, entry.value)
          val focus = core.text.focusTarget(handle.context, baseline.id.toDouble()).bounds
          val entryBounds = checkNotNull(entry.bounds) { "Text target ${baseline.id} must expose bounds" }
          assertEquals(focus.left, entryBounds.x, 0.0)
          assertEquals(focus.top, entryBounds.y, 0.0)
          assertEquals(entry.value, core.text.getEntries(handle.context).single().value)
        }
        val moved = baseline.copy(bounds = PageRect(120.0, 160.0, 180.0, 180.0),
          flowBounds = PageRect(120.0, 160.0, 220.0, 220.0), fontSize = 20.0)
        core.text.applyEdit(handle.context, baseline, moved)
        checkReaders(moved)
        handle.undo()
        checkReaders(baseline)
        handle.redo()
        checkReaders(moved)
        val edit = core.beginTextEdit(handle.context, baseline.id)
        core.updateTextEdit(edit, moved.copy(text = "cancelled"))
        core.cancelTextEdit()
        checkReaders(moved)
      }
      await { document.revertChanges() }
      instrumentation.runOnMainSync {
        val core = document.core
        val slot = checkNotNull(core.coordinator.textTarget(baseline.id))
        assertEquals(baseline, slot.state.annotation)
        handle.clear()
        assertNull(slot.state.annotation)
        assertEquals(baseline.canonicalPlacementBounds, slot.canonicalBounds)
        handle.setTextValue(baseline.id.toDouble(), "Reused", null)
        assertEquals(baseline.id, slot.state.annotation?.id)
        assertEquals(baseline.flowBounds, slot.state.annotation?.flowBounds)
        assertEquals(baseline.fontSize, slot.state.annotation?.fontSize)
        val emptyBounds = PageRect(24.0, 280.0, 120.0, 340.0)
        val emptyId = core.text.reserve(handle.context, emptyBounds)
        val emptySlot = checkNotNull(core.coordinator.textTarget(emptyId))
        val emptyEdit = core.beginTextEdit(handle.context, emptyId)
        core.updateTextEdit(emptyEdit, baseline.copy(id = emptyId, text = "discarded"))
        core.cancelTextEdit()
        assertNull(emptySlot.state.annotation)
        assertEquals(emptyBounds, emptySlot.canonicalBounds)
      }
    } finally {
      await { document.close() }
      source.delete()
    }
  }

  @Test
  fun acceptChangesQueuesAfterStructuralChangesAndKeepsAttachedIdentity() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = HybridInkSignDocument(instrumentation.targetContext)
    var view: HybridInkSignView? = null
    try {
      await { document.acceptChanges() }
      await { document.addPages(DocumentAddPagesOptions(type = null, tag = null,
        sources = arrayOf(source.path, source.path), imagePageSize = null, targetDpi = null, jpegQuality = null)) }
      instrumentation.runOnMainSync { view = viewer().also { it.document = document } }
      val page = await { document.getPage(PageQuery.create(0.0)) }
      var generation = 0L
      var ids = emptyList<String>()
      instrumentation.runOnMainSync {
        generation = document.core.coordinator.generation
        ids = document.core.coordinator.pages.map { it.id }
        document.core.coordinator.pages.forEachIndexed { index, item ->
          item.history.appendText(TextAnnotation(index.toLong() + 1, "Keep", PageRect(24.0, 40.0, 100.0, 60.0), 16.0))
        }
        assertTrue(document.getState().isDirty)
      }
      val rotation = AtomicReference<Promise<Unit>>()
      instrumentation.runOnMainSync { rotation.set(document.rotatePage(0.0, 90.0)) }
      await { document.acceptChanges() }
      await { rotation.get() }
      instrumentation.runOnMainSync {
        assertTrue(!document.getState().isDirty)
        assertTrue(!page.getState().canUndo && !page.getState().canRedo)
        assertEquals(ids, document.core.coordinator.pages.map { it.id })
        assertEquals(generation, document.core.coordinator.generation)
        assertEquals(90.0, page.getState().rotation, 0.0)
        assertTrue(view!!.document === document)
        document.core.coordinator.pages.forEach { item ->
          assertEquals("Keep", item.history.contentSnapshot().filterIsInstance<PageContent.Text>().single().annotation.text)
          assertTrue(!item.history.canUndo && !item.history.canRedo)
        }
      }
      await { document.acceptChanges() }
    } finally {
      instrumentation.runOnMainSync { view?.onDropView() }
      await { document.close() }
      source.delete()
    }
    assertTrue(runCatching { await { document.acceptChanges() } }.isFailure)
  }

  @Test
  fun acceptChangesSettlesActiveTextAndPreservesThePreparedHandle() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = HybridInkSignDocument(instrumentation.targetContext)
    try {
      await { document.addPages(DocumentAddPagesOptions(type = null, tag = null,
        sources = arrayOf(source.path), imagePageSize = null, targetDpi = null, jpegQuality = null)) }
      val page = await { document.getPage(PageQuery.create(0.0)) } as HybridDocumentPage
      var id = 0.0
      instrumentation.runOnMainSync {
        id = document.core.text.insert(page.context, TextAnnotationBounds(24.0, 40.0, 100.0, 60.0), "Original", null).id.toDouble()
        val edit = document.core.beginTextEdit(page.context, id.toLong())
        document.core.updateTextEdit(edit, checkNotNull(edit.current).copy(text = "Draft"))
      }
      await { document.acceptChanges() }
      instrumentation.runOnMainSync {
        assertNull(document.core.activeTextEdit)
        assertEquals("Draft", page.getTextValue(id))
        assertTrue(!document.getState().isDirty)
        page.setTextValue(id, "Next", null)
        assertTrue(document.getState().isDirty)
        page.undo()
        assertEquals("Draft", page.getTextValue(id))
        assertTrue(!document.getState().isDirty)
      }
    } finally {
      await { document.close() }
      source.delete()
    }
  }

  @Test
  fun acceptChangesSettlesNativeEditorWithoutLosingSelectionOrModeSession() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = HybridInkSignDocument(instrumentation.targetContext)
    var view: HybridInkSignView? = null
    lateinit var overlay: TextInteractionOverlay
    lateinit var editor: EditText
    lateinit var session: HybridModeSessionSpec
    var selectedId: Double? = null
    val selectionEvents = mutableListOf<TextSelection?>()
    try {
      await { document.addPages(DocumentAddPagesOptions(type = null, tag = null,
        sources = arrayOf(source.path), imagePageSize = null, targetDpi = null, jpegQuality = null)) }
      instrumentation.runOnMainSync {
        val owner = viewer().also { it.document = document }
        view = owner
        session = owner.setMode(InputMode.TEXT, null)
        val host = owner.view as FrameLayout
        val surface = host.getChildAt(0) as ViewerCanvas
        overlay = host.getChildAt(2) as TextInteractionOverlay
        val tap = checkNotNull(surface.textPresentationSnapshot()).transform.map(PagePoint(80.0, 100.0))
        val time = android.os.SystemClock.uptimeMillis()
        for ((action, stamp) in listOf(MotionEvent.ACTION_DOWN to time, MotionEvent.ACTION_UP to time + 10)) {
          val event = MotionEvent.obtain(time, stamp, action, tap.x.toFloat(), tap.y.toFloat(), 0)
          try { assertTrue(overlay.dispatchTouchEvent(event)) } finally { event.recycle() }
        }
        editor = (0 until overlay.childCount).map { overlay.getChildAt(it) }.filterIsInstance<EditText>().single()
        editor.setText("one\ntwo")
        selectedId = checkNotNull(overlay.selectedText()).textId
        owner.onTextSelectionChange = { selection -> selectionEvents.add(selection?.asSecondOrNull()) }
      }
      await { document.acceptChanges() }
      instrumentation.runOnMainSync {
        assertNull(editor.parent)
        assertEquals(selectedId, overlay.selectedText()?.textId)
        assertTrue("Reset must not emit an intermediate deselect/reselect", selectionEvents.isEmpty())
        assertTrue(!document.getState().isDirty)
        assertTrue(view!!.document === document)
      }
      val handle = await { session.getPage(null) }
      instrumentation.runOnMainSync {
        assertTrue(!handle.getState().canUndo && !handle.getState().canRedo)
      }
    } finally {
      instrumentation.runOnMainSync { view?.onDropView() }
      await { document.close() }
      source.delete()
    }
  }

  @Test
  fun revertChangesRestoresAcceptedStructureAndKeepsLaterUntrackedText() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = HybridInkSignDocument(instrumentation.targetContext)
    lateinit var baselineFile: File
    try {
      await { document.addPages(DocumentAddPagesOptions(type = null, tag = null,
        sources = arrayOf(source.path, source.path), imagePageSize = null, targetDpi = null, jpegQuality = null)) }
      val handle = await { document.getPage(PageQuery.create(0.0)) } as HybridDocumentPage
      var id = 0.0
      var permanentId = 0.0
      var ids = emptyList<String>()
      instrumentation.runOnMainSync {
        id = document.core.text.insert(handle.context, TextAnnotationBounds(24.0, 40.0, 100.0, 60.0), "Base").id.toDouble()
        ids = document.core.coordinator.pages.map { it.id }
        baselineFile = File(document.core.coordinator.sourcePath)
      }
      await { document.acceptChanges() }
      instrumentation.runOnMainSync {
        handle.setTextValue(id, "Tracked", null)
        permanentId = document.core.text.insert(handle.context, TextAnnotationBounds(24.0, 120.0, 100.0, 60.0),
          "Permanent", TextAnnotationOptions(untracked = true, font = null, fontSize = null, color = null,
            direction = null, maxLines = null, alignment = null, verticalAnchor = null)).id.toDouble()
      }
      await { document.removePage(0.0) }
      await { document.rotatePage(0.0, 90.0) }
      await { document.addPages(DocumentAddPagesOptions(type = null, tag = null,
        sources = arrayOf(source.path), imagePageSize = null, targetDpi = null, jpegQuality = null)) }
      await { document.movePage(0.0, 1.0) }
      assertTrue("Accepted source must survive structural mutations", baselineFile.exists())
      await { document.revertChanges() }
      instrumentation.runOnMainSync {
        assertEquals(ids, document.core.coordinator.pages.map { it.id })
        assertEquals("Base", handle.getTextValue(id))
        assertEquals("Permanent", handle.getTextValue(permanentId))
        assertTrue(!document.getState().isDirty)
        document.core.coordinator.pages.forEach { page ->
          assertEquals(0, page.dimensions.rotation)
          assertTrue(!page.history.canUndo && !page.history.canRedo)
        }
        handle.setTextValue(id, "Next", null)
        assertTrue(document.getState().isDirty)
        handle.undo()
        assertEquals("Base", handle.getTextValue(id))
      }
      await { document.revertChanges() }
      await { document.rotatePage(0.0, 90.0) }
      await { document.acceptChanges() }
      assertTrue("Replacing the baseline releases the previous source", !baselineFile.exists())
      await { document.rotatePage(0.0, 90.0) }
      await { document.revertChanges() }
      instrumentation.runOnMainSync { assertEquals(90.0, handle.getState().rotation, 0.0) }
    } finally {
      await { document.close() }
      source.delete()
    }
  }

  @Test
  fun revertChangesRestoresAnEmptyAttachedDocumentWithoutClosingIt() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val source = source()
    val document = HybridInkSignDocument(instrumentation.targetContext)
    var view: HybridInkSignView? = null
    try {
      instrumentation.runOnMainSync { view = viewer().also { it.document = document } }
      await { document.addPages(DocumentAddPagesOptions(type = null, tag = null,
        sources = arrayOf(source.path), imagePageSize = null, targetDpi = null, jpegQuality = null)) }
      await { document.revertChanges() }
      instrumentation.runOnMainSync {
        assertEquals(0.0, document.pageCount, 0.0)
        assertTrue(!document.getState().isDirty)
        assertTrue(view!!.document === document)
      }
      await { document.revertChanges() }
      await { document.addPages(DocumentAddPagesOptions(type = null, tag = null,
        sources = arrayOf(source.path), imagePageSize = null, targetDpi = null, jpegQuality = null)) }
      await { document.acceptChanges() }
      await { document.rotatePage(0.0, 90.0) }
      await { document.revertChanges() }
      instrumentation.runOnMainSync { assertEquals(1.0, document.pageCount, 0.0) }
    } finally {
      instrumentation.runOnMainSync { view?.onDropView() }
      await { document.close() }
      source.delete()
    }
  }

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
      await { document.rotatePage(0.0, 90.0) }
      await { document.revertChanges() }
      instrumentation.runOnMainSync {
        assertEquals(0.0, page.getState().rotation, 0.0)
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
