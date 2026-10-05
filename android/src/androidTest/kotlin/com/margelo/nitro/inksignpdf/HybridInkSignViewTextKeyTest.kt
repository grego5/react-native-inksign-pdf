package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
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
