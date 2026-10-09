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
    val source = File.createTempFile("captured-prepared-page-", ".pdf", context.cacheDir)
      .apply { writeText("controlled test source") }
    val analysisStarted = CountDownLatch(1)
    val releaseAnalysis = CountDownLatch(1)
    val blockAnalysis = AtomicBoolean(false)
    val resourceRef = AtomicReference<BlockingAnalysisResource>()
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
        ).also(resourceRef::set)
      },
    )
    val viewRef = AtomicReference<HybridInkSignView>()
    val surfaceRef = AtomicReference<SurfaceView>()

    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context, worker)
        viewRef.set(view)
        val host = view.view
        val exactSize = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        host.measure(exactSize, exactSize)
        host.layout(0, 0, 300, 300)
        surfaceRef.set((host as FrameLayout).getChildAt(0) as SurfaceView)
      }
      awaitOpen(instrumentation, viewRef.get(), source.absolutePath)

      val textContentChanges = AtomicInteger()
      instrumentation.runOnMainSync {
        val surface = surfaceRef.get()
        val previousCallback = surface.onTextContentChanged
        surface.onTextContentChanged = {
          textContentChanges.incrementAndGet()
          previousCallback?.invoke()
        }
      }

      val pageZero = awaitPreparedPage(instrumentation, viewRef.get(), 0.0)
      instrumentation.runOnMainSync {
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
      val prepared = AtomicReference<Promise<HybridAnalyzedPageSpec>>()
      blockAnalysis.set(true)
      instrumentation.runOnMainSync {
        prepared.set(viewRef.get().getPage(0.0))
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
      assertEquals(before.get()[0].content.size + 1, after.get()[0].content.size)
      assertEquals(
        listOf("page zero", "new value"),
        after.get()[0].content.mapNotNull { it.textAnnotationOrNull()?.text },
      )
      assertEquals(
        listOf("page one"),
        after.get()[1].content.mapNotNull { it.textAnnotationOrNull()?.text },
      )
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
    val sourceA = File.createTempFile("selected-text-handle-a-", ".pdf", context.cacheDir)
      .apply { writeText("controlled source A") }
    val sourceB = File.createTempFile("selected-text-handle-b-", ".pdf", context.cacheDir)
      .apply { writeText("controlled source B") }
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
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context, worker)
        viewRef.set(view)
        val size = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        view.view.measure(size, size)
        view.view.layout(0, 0, 300, 300)
      }
      val view = viewRef.get()
      awaitOpen(instrumentation, view, sourceA.absolutePath)
      val page = awaitPreparedPage(view.getPage(0.0))
      val bounds = TextAnnotationBounds(40.0, 60.0, 160.0, 40.0)
      val textId = setPreparedText(page, bounds, "note")
      val host = view.view as FrameLayout
      val surface = host.getChildAt(0) as SurfaceView
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
      handle.setValue("updated")
      handle.setOptions(TextAnnotationOptions(
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
      handle.setValue("")
      assertEquals("", handle.getValue())

      awaitOpen(instrumentation, view, sourceB.absolutePath)
      try {
        handle.getValue()
        throw AssertionError("replacement must invalidate the old handle")
      } catch (error: PdfSessionException) {
        assertEquals("operation_cancelled", error.code)
      }
      assertTrue("replacement must clear selection", view.getSelectedText().isSecond)
      assertTrue("replacement must not inherit old text targets",
        awaitPreparedPage(view.getPage(0.0)).getTextEntries().isEmpty())
    } finally {
      releaseAnalysis.countDown()
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      sourceA.delete()
      sourceB.delete()
    }
  }

  @Test
  fun replacementCancelsPendingPreparedPageAndInstallsOnlyNewDocument() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val sourceA = File.createTempFile("replace-prepared-page-a-", ".pdf", context.cacheDir)
      .apply { writeText("controlled source A") }
    val sourceB = File.createTempFile("replace-prepared-page-b-", ".pdf", context.cacheDir)
      .apply { writeText("controlled source B") }
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
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context, worker)
        viewRef.set(view)
        val exactSize = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        view.view.measure(exactSize, exactSize)
        view.view.layout(0, 0, 300, 300)
      }
      awaitOpen(instrumentation, viewRef.get(), sourceA.absolutePath, expectedPageCount = 1.0)
      val originalPath = viewRef.get().coordinator.sourcePath

      val lookupSettled = CountDownLatch(1)
      val rejectionCount = AtomicInteger()
      val lookupError = AtomicReference<Throwable>()
      val lookup = AtomicReference<Promise<HybridAnalyzedPageSpec>>()
      blockAnalysis.set(true)
      instrumentation.runOnMainSync {
        lookup.set(viewRef.get().getPage(0.0))
      }
      lookup.get().then { lookupSettled.countDown() }
        .catch { error -> lookupError.set(error); rejectionCount.incrementAndGet(); lookupSettled.countDown() }
      assertTrue("prepared page analysis did not reach the worker", analysisStarted.await(10L, TimeUnit.SECONDS))

      val openSettled = CountDownLatch(1)
      val replacementInfo = AtomicReference<PageInfo>()
      val replacementError = AtomicReference<Throwable>()
      val replacement = AtomicReference<Promise<PageInfo>>()
      instrumentation.runOnMainSync {
        replacement.set(viewRef.get().open(sourceB.absolutePath, null))
        assertTrue("replacement did not clear the active document", !viewRef.get().coordinator.hasDocument)
      }
      replacement.get().then { info -> replacementInfo.set(info); openSettled.countDown() }
        .catch { error -> replacementError.set(error); openSettled.countDown() }

      assertTrue("stale key lookup did not cancel promptly", lookupSettled.await(5L, TimeUnit.SECONDS))
      assertEquals("operation_cancelled", (lookupError.get() as? PdfSessionException)?.code)
      assertEquals(1, rejectionCount.get())
      releaseAnalysis.countDown()
      assertTrue("replacement open did not settle", openSettled.await(10L, TimeUnit.SECONDS))
      replacementError.get()?.let { throw AssertionError("replacement open failed", it) }
      assertEquals(1.0, replacementInfo.get().pageCount, 0.0)
      instrumentation.runOnMainSync {
        assertTrue(viewRef.get().coordinator.sourcePath != originalPath)
        assertTrue(viewRef.get().coordinator.pageSnapshot(0).content.isEmpty())
      }
    } finally {
      releaseAnalysis.countDown()
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      sourceA.delete()
      sourceB.delete()
    }
  }

  @Test
  fun modeSessionCancelsWorkerPreparationAndQueuedFocusButKeepsCommittedText() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("mode-session-", ".pdf", context.cacheDir)
      .apply { writeText("controlled source") }
    val analysisStarted = CountDownLatch(1)
    val releaseAnalysis = CountDownLatch(1)
    val blockAnalysis = AtomicBoolean(false)
    val worker = PdfSessionWorker(opener = PdfSessionOpener { path, generation ->
      BlockingAnalysisResource(PdfSessionInfo(path, listOf(PdfPageDimensions(300.0, 300.0)), generation),
        analysisStarted, releaseAnalysis, blockAnalysis)
    })
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context, worker)
        viewRef.set(view)
        val size = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        view.view.measure(size, size)
        view.view.layout(0, 0, 300, 300)
      }
      val view = viewRef.get()
      awaitOpen(instrumentation, view, source.absolutePath, expectedPageCount = 1.0)
      val ordinary = awaitPreparedPage(view.getPage(null))
      val session = view.setMode(InputMode.INK, null)
      val scoped = awaitPreparedPage(session.getPage(null))
      val id = scoped.resolveText(ResolveTextOptions(
        fieldName = null, bounds = TextAnnotationBounds(50.0, 60.0, 100.0, 30.0),
        occurrence = null, fontSize = null, color = null, direction = null,
        maxLines = null, alignment = null, verticalAnchor = null,
      ))
      scoped.setTextValue(id, "Ada")
      val before = view.getViewport()
      blockAnalysis.set(true)
      val pending = session.getPage(null)
      assertTrue("analysis did not reach worker", analysisStarted.await(10, TimeUnit.SECONDS))
      val cancelled = CountDownLatch(2)
      val errors = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
      pending.then { throw AssertionError("Cancelled acquisition returned a page") }
        .catch { errors.add(it); cancelled.countDown() }
      val focus = scoped.focusText(id, TextFocusOptions(3.0, null, null))
      focus.then { throw AssertionError("Cancelled focus completed") }
        .catch { errors.add(it); cancelled.countDown() }
      view.setMode(InputMode.INK, null) // A repeated request still creates a new session.
      assertTrue("mode cancellation must not wait for the worker", cancelled.await(5, TimeUnit.SECONDS))
      assertEquals(2, errors.size)
      assertTrue(errors.all { it is PdfSessionException && it.code == "operation_cancelled" })
      try { scoped.setTextValue(id, "Stale"); throw AssertionError("Stale write admitted") }
      catch (error: PdfSessionException) { assertEquals("operation_cancelled", error.code) }
      assertEquals("Ada", ordinary.getTextValue(id))
      releaseAnalysis.countDown()
      awaitPreparedPage(view.getPage(null)) // Drain the held worker and cancelled focus.
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

  private fun awaitPreparedPage(promise: Promise<HybridAnalyzedPageSpec>): HybridAnalyzedPageSpec {
    val settled = CountDownLatch(1)
    val page = AtomicReference<HybridAnalyzedPageSpec>()
    val failure = AtomicReference<Throwable>()
    promise.then { page.set(it); settled.countDown() }
      .catch { failure.set(it); settled.countDown() }
    assertTrue("prepared page timed out", settled.await(20, TimeUnit.SECONDS))
    failure.get()?.let { throw AssertionError("prepared page failed", it) }
    return page.get()
  }

  private fun pageHistoryStates(view: HybridInkSignView): List<PageHistoryState> =
    (0..1).map { pageIndex ->
      PageHistoryState(
        content = view.coordinator.pageSnapshot(pageIndex).content,
        revision = view.coordinator.pageHistoryRevision(pageIndex),
      )
    }

  private fun awaitOpen(
    instrumentation: android.app.Instrumentation,
    view: HybridInkSignView,
    sourcePath: String,
    expectedPageCount: Double = 2.0,
  ) {
    val settled = CountDownLatch(1)
    val result = AtomicReference<PageInfo>()
    val failure = AtomicReference<Throwable>()
    val open = AtomicReference<Promise<PageInfo>>()
    instrumentation.runOnMainSync { open.set(view.open(sourcePath, null)) }
    open.get().then { pageInfo -> result.set(pageInfo); settled.countDown() }
      .catch { error -> failure.set(error); settled.countDown() }
    assertTrue("open did not settle", settled.await(10L, TimeUnit.SECONDS))
    failure.get()?.let { throw AssertionError("controlled document open failed", it) }
    assertEquals(expectedPageCount, result.get().pageCount, 0.0)
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
    override fun preparePageAnalysis(pageIndex: Int): PdfiumPreparedPageAnalysis {
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
