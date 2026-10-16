package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.margelo.nitro.core.Promise
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class HybridInkSignViewTextKeyTest {
  @Test
  fun preparedPageWriteCompletesOnCapturedPageAfterNavigation() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = copyFixturePdf(context, "captured-prepared-page-")
    val analysisStarted = CountDownLatch(1)
    val releaseAnalysis = CountDownLatch(1)
    val blockAnalysis = AtomicBoolean(false)
    val resourceRef = AtomicReference<BlockingAnalysisResource>()
    val worker = PdfSessionWorker(
      opener = PdfSessionOpener { path, generation ->
        BlockingAnalysisResource(
          PdfSessionInfo(
            sourcePath = path,
            pages = List(3) { PdfPageDimensions(300.0, 300.0) },
            generation = generation,
          ),
          analysisStarted,
          releaseAnalysis,
          blockAnalysis,
        ).also(resourceRef::set)
      },
    )
    val document = HybridInkSignDocument(DocumentCore(
      context, worker, recordHistory = true, exportOwnership = ExportOwnership.DOCUMENT,
    ))
    val viewRef = AtomicReference<HybridInkSignView>()
    val surfaceRef = AtomicReference<ViewerCanvas>()

    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context).also { it.document = document }
        viewRef.set(view)
        assertTrue("An empty document has no matching page IDs", document.getPageIdsByTag("report").isEmpty())
        val host = view.view
        val exactSize = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        host.measure(exactSize, exactSize)
        host.layout(0, 0, 300, 300)
        surfaceRef.set((host as FrameLayout).getChildAt(0) as ViewerCanvas)
      }
      awaitOpen(instrumentation, document, source.absolutePath, expectedPageCount = 3.0, tag = "report")
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        val ids = document.getPageIdsByTag("report").toList()
        assertEquals((0 until 3).map { view.documentState.pageMetadata(it).id }, ids)
        assertTrue(document.getPageIdsByTag("Report").isEmpty())
        assertEquals(0, view.documentState.activePageIndex)
        assertTrue(!document.getState().isDirty)
      }
      assertTrue("ID lookup must not prepare analysis", resourceRef.get().analysisRequests.isEmpty())
      val missesSettled = CountDownLatch(2)
      val missErrors = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
      instrumentation.runOnMainSync {
        listOf(TaggedPageQuery("missing", null), TaggedPageQuery("report", 3.0)).forEach { query ->
          document.getPage(PageQuery.create(query))
            .then { missErrors.add(AssertionError("Missing tagged page returned a handle")); missesSettled.countDown() }
            .catch { missErrors.add(it); missesSettled.countDown() }
        }
      }
      assertTrue("missing tagged lookups did not settle", missesSettled.await(10L, TimeUnit.SECONDS))
      assertEquals(2, missErrors.size)
      assertTrue(missErrors.all { it is PdfSessionException && it.code == "page_not_found" })
      assertTrue(resourceRef.get().analysisRequests.isEmpty())

      val textContentChanges = AtomicInteger()
      instrumentation.runOnMainSync {
        val surface = surfaceRef.get()
        val previousCallback = surface.onTextContentChanged
        surface.onTextContentChanged = {
          textContentChanges.incrementAndGet()
          previousCallback?.invoke()
        }
      }

      val pageZero = awaitPreparedPage(instrumentation, viewRef.get(), tag = "report")
      assertEquals("Only the selected match should be prepared", listOf(0), resourceRef.get().analysisRequests.toList())
      instrumentation.runOnMainSync {
        assertEquals("report", pageZero.getState().tag)
        assertEquals(0.0, pageZero.getState().pageIndex, 0.0)
        setPreparedText(pageZero, TextAnnotationBounds(20.0, 20.0, 120.0, 30.0), "page zero")
        surfaceRef.get().switchPage(1)
      }
      val pageOne = awaitPreparedPage(instrumentation, viewRef.get(), 1.0)
      instrumentation.runOnMainSync {
        setPreparedText(pageOne, TextAnnotationBounds(20.0, 20.0, 120.0, 30.0), "page one")
        surfaceRef.get().switchPage(0)
      }

      val before = AtomicReference<List<PageHistoryState>>()
      instrumentation.runOnMainSync {
        before.set(pageHistoryStates(viewRef.get()))
      }

      val settled = CountDownLatch(1)
      val failure = AtomicReference<Throwable>()
      val prepared = AtomicReference<Promise<HybridDocumentPageSpec>>()
      blockAnalysis.set(true)
      instrumentation.runOnMainSync {
        prepared.set(document.getPage(PageQuery.create(TaggedPageQuery("report", 2.0))))
      }
      prepared.get().then { page ->
        setPreparedText(page, TextAnnotationBounds(20.0, 60.0, 120.0, 30.0), "new value")
        settled.countDown()
      }.catch { error -> failure.set(error); settled.countDown() }

      assertTrue("prepared page analysis did not reach the worker", analysisStarted.await(10L, TimeUnit.SECONDS))
      instrumentation.runOnMainSync { surfaceRef.get().switchPage(1) }
      val changesBeforeCommit = AtomicInteger()
      instrumentation.runOnMainSync { changesBeforeCommit.set(textContentChanges.get()) }
      releaseAnalysis.countDown()
      assertTrue("prepared page command did not settle", settled.await(10L, TimeUnit.SECONDS))
      assertTrue("captured-page write failed after navigation: ${failure.get()}", failure.get() == null)
      assertEquals("an inactive-page commit must not sync the active overlay",
        changesBeforeCommit.get(), textContentChanges.get())

      val after = AtomicReference<List<PageHistoryState>>()
      instrumentation.runOnMainSync {
        after.set(pageHistoryStates(viewRef.get()))
      }
      assertEquals(before.get()[2].content.size + 1, after.get()[2].content.size)
      assertEquals(
        listOf("page zero"),
        after.get()[0].content.mapNotNull { it.textAnnotationOrNull()?.text },
      )
      assertEquals(
        listOf("page one"),
        after.get()[1].content.mapNotNull { it.textAnnotationOrNull()?.text },
      )
      assertEquals(listOf("new value"), after.get()[2].content.mapNotNull { it.textAnnotationOrNull()?.text })
      assertTrue("the controlled PDF session was not opened", resourceRef.get() != null)
    } finally {
      releaseAnalysis.countDown()
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      source.delete()
    }
  }

  @Test
  fun selectedTextHandleSurvivesDeselectionAndNavigationAndRejectsReplacement() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val sourceA = copyFixturePdf(context, "selected-text-handle-a-")
    val sourceB = copyFixturePdf(context, "selected-text-handle-b-")
    val analysisStarted = CountDownLatch(1)
    val releaseAnalysis = CountDownLatch(1)
    val blockAnalysis = AtomicBoolean(false)
    val worker = PdfSessionWorker(
      opener = PdfSessionOpener { path, generation ->
        BlockingAnalysisResource(
          PdfSessionInfo(
            sourcePath = path,
            pages = listOf(PdfPageDimensions(300.0, 300.0), PdfPageDimensions(300.0, 300.0)),
            generation = generation,
          ),
          analysisStarted,
          releaseAnalysis,
          blockAnalysis,
        )
      },
    )
    val document = HybridInkSignDocument(DocumentCore(
      context, worker, recordHistory = true, exportOwnership = ExportOwnership.DOCUMENT,
    ))
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context).also { it.document = document }
        viewRef.set(view)
        val size = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        view.view.measure(size, size)
        view.view.layout(0, 0, 300, 300)
      }
      val view = viewRef.get()
      awaitOpen(instrumentation, document, sourceA.absolutePath)
      val page = awaitPreparedPage(document.getPage(PageQuery.create(0.0)))
      val bounds = TextAnnotationBounds(40.0, 60.0, 160.0, 40.0)
      val textId = setPreparedText(page, bounds, "note")
      val host = view.view as FrameLayout
      val surface = host.getChildAt(0) as ViewerCanvas
      val overlay = host.getChildAt(2) as TextInteractionOverlay
      assertTrue("an idle view must return null", view.getSelectedText().isSecond)

      val selected = AtomicReference<Variant_HybridTextHandleSpec_NullType>()
      instrumentation.runOnMainSync {
        val presentation = checkNotNull(surface.textPresentationSnapshot())
        val annotation = presentation.annotations.single { it.id.toDouble() == textId }
        val point = presentation.forAnnotation(annotation).transform.map(PagePoint(
          (annotation.bounds.left + annotation.bounds.right) / 2.0,
          (annotation.bounds.top + annotation.bounds.bottom) / 2.0,
        ))
        val down = MotionEvent.obtain(1_000L, 1_000L, MotionEvent.ACTION_DOWN,
          point.x.toFloat(), point.y.toFloat(), 0)
        val up = MotionEvent.obtain(1_000L, 1_010L, MotionEvent.ACTION_UP,
          point.x.toFloat(), point.y.toFloat(), 0)
        try {
          assertTrue(overlay.onTouchEvent(down))
          assertTrue(overlay.onTouchEvent(up))
          selected.set(view.getSelectedText())
        } finally {
          down.recycle()
          up.recycle()
        }
      }
      val handle = checkNotNull(selected.get().asFirstOrNull())
      assertEquals("note", handle.getValue())

      instrumentation.runOnMainSync {
        overlay.finishForLifecycle()
        surface.switchPage(1)
      }
      handle.setValue("updated", null)
      handle.setOptions(TextAnnotationOptions(untracked = null, font = null,
        fontSize = null,
        color = null,
        direction = null,
        maxLines = null,
        alignment = TextAlignment.CENTER,
        verticalAnchor = null,
      ))
      assertTrue("font size adjustment must return a positive size", handle.adjustSize(1.0) > 0.0)
      assertEquals("updated", handle.getValue())
      assertEquals("updated", page.getTextValue(textId))
      handle.setValue("", null)
      assertEquals("", handle.getValue())

      awaitOpen(instrumentation, document, sourceB.absolutePath)
      try {
        handle.getValue()
        throw AssertionError("replacement must invalidate the old handle")
      } catch (error: PdfSessionException) {
        assertEquals("operation_cancelled", error.code)
      }
      assertTrue("replacement must clear selection", view.getSelectedText().isSecond)
      assertTrue("replacement must not inherit old text targets",
        awaitPreparedPage(document.getPage(PageQuery.create(0.0))).getInputTargets().isEmpty())
    } finally {
      releaseAnalysis.countDown()
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      sourceA.delete()
      sourceB.delete()
    }
  }

  @Test
  fun replacingViewerOwnerDoesNotCancelOrdinaryPageLookup() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val sourceA = copyFixturePdf(context, "replace-prepared-page-a-")
    val sourceB = copyFixturePdf(context, "replace-prepared-page-b-")
    val analysisStarted = CountDownLatch(1)
    val releaseAnalysis = CountDownLatch(1)
    val blockAnalysis = AtomicBoolean(false)
    val worker = PdfSessionWorker(
      opener = PdfSessionOpener { path, generation ->
        BlockingAnalysisResource(
          PdfSessionInfo(
            sourcePath = path,
            pages = listOf(PdfPageDimensions(300.0, 300.0)),
            generation = generation,
          ),
          analysisStarted,
          releaseAnalysis,
          blockAnalysis,
        )
      },
    )
    val documentA = HybridInkSignDocument(DocumentCore(
      context, worker, recordHistory = true, exportOwnership = ExportOwnership.DOCUMENT,
    ))
    val documentB = HybridInkSignDocument(DocumentCore(
      context,
      PdfSessionWorker(opener = PdfSessionOpener { path, generation ->
        BlockingAnalysisResource(
          PdfSessionInfo(path, listOf(PdfPageDimensions(300.0, 300.0)), generation),
          CountDownLatch(0), CountDownLatch(0), AtomicBoolean(false),
        )
      }),
      recordHistory = true,
      exportOwnership = ExportOwnership.DOCUMENT,
    ))
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context).also { it.document = documentA }
        viewRef.set(view)
        val exactSize = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        view.view.measure(exactSize, exactSize)
        view.view.layout(0, 0, 300, 300)
      }
      awaitOpen(instrumentation, documentA, sourceA.absolutePath, expectedPageCount = 1.0, tag = "owner-a")
      awaitOpen(instrumentation, documentB, sourceB.absolutePath, expectedPageCount = 1.0, tag = "owner-b")

      val lookupSettled = CountDownLatch(1)
      val rejectionCount = AtomicInteger()
      val lookupError = AtomicReference<Throwable>()
      val lookup = AtomicReference<Promise<HybridDocumentPageSpec>>()
      blockAnalysis.set(true)
      instrumentation.runOnMainSync {
        lookup.set(documentA.getPage(PageQuery.create(0.0)))
      }
      lookup.get().then { lookupSettled.countDown() }
        .catch { error -> lookupError.set(error); rejectionCount.incrementAndGet(); lookupSettled.countDown() }
      assertTrue("prepared page analysis did not reach the worker", analysisStarted.await(10L, TimeUnit.SECONDS))
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        view.document = documentB
        assertTrue("viewer did not install owner B", view.document === documentB)
        assertEquals("owner-b", view.documentState.pageMetadata(0).tag)
      }

      assertTrue("owner A lookup completed before its analysis was released", !lookupSettled.await(250L, TimeUnit.MILLISECONDS))
      assertEquals(0, rejectionCount.get())
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        assertTrue("viewer changed owners while analysis was blocked", view.document === documentB)
        assertEquals("owner-b", view.documentState.pageMetadata(0).tag)
      }
      releaseAnalysis.countDown()
      assertTrue("owner A page lookup did not complete", lookupSettled.await(10L, TimeUnit.SECONDS))
      lookupError.get()?.let { throw AssertionError("ordinary owner A lookup failed", it) }
      assertEquals(0, rejectionCount.get())
      val pageA = awaitPreparedPage(lookup.get())
      assertTrue(documentA.getPageIdsByTag("owner-a").contains(pageA.getState().pageId))
      assertEquals(1.0, documentA.getState().pageCount, 0.0)
      assertEquals(1.0, documentB.getState().pageCount, 0.0)
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        assertTrue("owner A result was published into viewer B", view.document === documentB)
        assertEquals("owner-b", view.documentState.pageMetadata(0).tag)
      }
    } finally {
      releaseAnalysis.countDown()
      instrumentation.runOnMainSync {
        viewRef.get()?.let { view ->
          view.document = null
          view.onDropView()
        }
      }
      awaitClose(instrumentation, documentA)
      awaitClose(instrumentation, documentB)
      sourceA.delete()
      sourceB.delete()
    }
  }

  @Test
  fun modeSessionCancelsWorkerPreparationAndQueuedFocusButKeepsCommittedText() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = copyFixturePdf(context, "mode-session-")
    val analysisStarted = CountDownLatch(1)
    val releaseAnalysis = CountDownLatch(1)
    val blockAnalysis = AtomicBoolean(false)
    val worker = PdfSessionWorker(opener = PdfSessionOpener { path, generation ->
      BlockingAnalysisResource(PdfSessionInfo(path, List(2) { PdfPageDimensions(300.0, 300.0) }, generation),
        analysisStarted, releaseAnalysis, blockAnalysis)
    })
    val document = HybridInkSignDocument(DocumentCore(
      context, worker, recordHistory = true, exportOwnership = ExportOwnership.DOCUMENT,
    ))
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context).also { it.document = document }
        viewRef.set(view)
        val size = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        view.view.measure(size, size)
        view.view.layout(0, 0, 300, 300)
      }
      val view = viewRef.get()
      awaitOpen(instrumentation, document, source.absolutePath, tag = "report")
      val ordinary = awaitPreparedPage(document.getPage(PageQuery.create(0.0)))
      val session = view.setMode(InputMode.INK, null)
      val scoped = awaitPreparedPage(session.getPage(
        Variant_Double_TaggedPageQuery.create(TaggedPageQuery("report", null))))
      val id = scoped.resolveInputTarget(InputTargetResolutionOptions(font = null,
        fieldName = null, bounds = TextAnnotationBounds(50.0, 60.0, 100.0, 30.0),
        occurrence = null, fontSize = null, color = null, direction = null,
        maxLines = null, alignment = null, verticalAnchor = null,
      ))
      scoped.setTextValue(id, "Ada", null)
      val before = view.getViewport()
      blockAnalysis.set(true)
      val pending = session.getPage(
        Variant_Double_TaggedPageQuery.create(TaggedPageQuery("report", 1.0)))
      assertTrue("analysis did not reach worker", analysisStarted.await(10, TimeUnit.SECONDS))
      val cancelled = CountDownLatch(2)
      val errors = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
      pending.then { throw AssertionError("Cancelled acquisition returned a page") }
        .catch { errors.add(it); cancelled.countDown() }
      val focus = session.focusInputTarget(scoped, id, InputTargetFocusOptions(3.0, null, null))
      focus.then { throw AssertionError("Cancelled focus completed") }
        .catch { errors.add(it); cancelled.countDown() }
      view.setMode(InputMode.INK, null) // A repeated request still creates a new session.
      assertTrue("mode cancellation must not wait for the worker", cancelled.await(5, TimeUnit.SECONDS))
      assertEquals(2, errors.size)
      assertTrue(errors.all { it is PdfSessionException && it.code == "operation_cancelled" })
      try { scoped.setTextValue(id, "Stale", null); throw AssertionError("Stale write admitted") }
      catch (error: PdfSessionException) { assertEquals("operation_cancelled", error.code) }
      assertEquals("Ada", ordinary.getTextValue(id))
      releaseAnalysis.countDown()
      awaitPreparedPage(document.getPage(PageQuery.create(0.0))) // Drain the held worker and cancelled focus.
      val after = view.getViewport()
      assertEquals(before.zoom, after.zoom, 0.001)
      assertEquals(before.x, after.x, 0.001)
      assertEquals(before.y, after.y, 0.001)
      assertEquals("Ada", ordinary.getTextValue(id))
    } finally {
      releaseAnalysis.countDown()
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      source.delete()
    }
  }

  private fun awaitPreparedPage(promise: Promise<HybridDocumentPageSpec>): HybridDocumentPageSpec {
    val settled = CountDownLatch(1)
    val page = AtomicReference<HybridDocumentPageSpec>()
    val failure = AtomicReference<Throwable>()
    promise.then { page.set(it); settled.countDown() }
      .catch { failure.set(it); settled.countDown() }
    assertTrue("prepared page timed out", settled.await(20, TimeUnit.SECONDS))
    failure.get()?.let { throw AssertionError("prepared page failed", it) }
    return page.get()
  }

  private fun pageHistoryStates(view: HybridInkSignView): List<PageHistoryState> =
    (0 until view.documentState.pageCount).map { pageIndex ->
      PageHistoryState(
        content = view.documentState.pageSnapshot(pageIndex).content,
        revision = view.documentState.pageHistoryRevision(pageIndex),
      )
    }

  private fun awaitOpen(
    instrumentation: android.app.Instrumentation,
    document: HybridInkSignDocument,
    sourcePath: String,
    expectedPageCount: Double = 2.0,
    tag: String? = null,
  ) {
    val settled = CountDownLatch(1)
    val result = AtomicReference<HybridInkSignDocumentSpec>()
    val failure = AtomicReference<Throwable>()
    val open = AtomicReference<Promise<HybridInkSignDocumentSpec>>()
    instrumentation.runOnMainSync {
      open.set(document.open(sourcePath, DocumentOpenOptions(
        recordHistory = null, tag = tag, imagePageSize = null, targetDpi = null,
        jpegQuality = null, androidFallbackFont = null,
      )))
    }
    open.get().then { opened -> result.set(opened); settled.countDown() }
      .catch { error -> failure.set(error); settled.countDown() }
    assertTrue("open did not settle", settled.await(10L, TimeUnit.SECONDS))
    failure.get()?.let { throw AssertionError("controlled document open failed", it) }
    assertEquals(expectedPageCount, document.getState().pageCount, 0.0)
  }

  private fun awaitClose(instrumentation: android.app.Instrumentation, document: HybridInkSignDocument) {
    val settled = CountDownLatch(1)
    val failure = AtomicReference<Throwable>()
    instrumentation.runOnMainSync {
      document.close().then { settled.countDown() }
        .catch { error -> failure.set(error); settled.countDown() }
    }
    assertTrue("document close did not settle", settled.await(10L, TimeUnit.SECONDS))
    failure.get()?.let { throw AssertionError("document close failed", it) }
  }

  private fun copyFixturePdf(context: android.content.Context, prefix: String): File {
    val source = File.createTempFile(prefix, ".pdf", context.cacheDir)
    context.assets.open("horizontal-rule-lines.pdf").use { fixture ->
      source.outputStream().use { output -> fixture.copyTo(output) }
    }
    return source
  }

  private data class PageHistoryState(
    val content: List<PageContent>,
    val revision: Long,
  )

  private class BlockingAnalysisResource(
    override val info: PdfSessionInfo,
    private val analysisStarted: CountDownLatch,
    private val releaseAnalysis: CountDownLatch,
    private val blockAnalysis: AtomicBoolean,
  ) : PdfSessionResource {
    val analysisRequests = java.util.concurrent.CopyOnWriteArrayList<Int>()
    override fun preparePageAnalysis(pageIndex: Int): PdfiumPreparedPageAnalysis {
      analysisRequests += pageIndex
      if (blockAnalysis.get()) {
        analysisStarted.countDown()
        check(releaseAnalysis.await(10L, TimeUnit.SECONDS)) { "test did not release prepared analysis" }
      }
      return PdfiumPreparedPageAnalysis(300.0, 300.0, emptyList(), emptyList())
    }

    override fun renderTiles(requests: List<PdfTileRequest>, beforeEach: () -> Unit): List<PdfTile> {
      requests.forEach { beforeEach() }
      return emptyList()
    }

    override fun renderPreview(request: PdfTileRequest, beforeRender: () -> Unit): PdfTile {
      beforeRender()
      return PdfTile(
        request,
        Bitmap.createBitmap(request.widthPx.coerceAtLeast(1), request.heightPx.coerceAtLeast(1),
          Bitmap.Config.ARGB_8888),
      )
    }

    override fun close() = Unit
  }
}
