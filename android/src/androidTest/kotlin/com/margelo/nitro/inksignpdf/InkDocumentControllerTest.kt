package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.MotionEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class InkDocumentControllerTest {
  private val instrumentation = InstrumentationRegistry.getInstrumentation()
  private val context: Context = instrumentation.targetContext

  @Test
  fun sameLevelPanUpdatesDisplayedRequestsImmediately() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    try {
      harness.runOnMain {
        harness.controller.setZoomForTest(1.0, PagePoint(2500.0, 2500.0))
      }
      harness.awaitState { !it.transitionPending && it.pendingKeys.isEmpty() }
      val before = harness.state()

      harness.runOnMain {
        harness.controller.setZoomForTest(1.0, PagePoint(1000.0, 1000.0))
      }
      val after = harness.state()

      assertNotEquals(before.activeVisibleKeys, after.activeVisibleKeys)
      assertEquals(
        before.activeVisibleKeys.map { it.level }.toSet(),
        after.activeVisibleKeys.map { it.level }.toSet(),
      )
      assertEquals(after.activeVisibleKeys, after.displayedVisibleKeys)
      assertFalse(after.transitionPending)
    } finally {
      harness.close()
    }
  }

  @Test
  fun levelChangeRetainsDisplayedRequestsUntilCoverageCompletes() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    try {
      val before = harness.state()
      val started = harness.session.blockNextRender()

      harness.runOnMain {
        harness.controller.setZoomForTest(1.0, PagePoint(2500.0, 2500.0))
      }
      assertTrue(started.await(5L, TimeUnit.SECONDS))
      val during = harness.state()

      assertTrue(during.transitionPending)
      assertEquals(before.displayedVisibleKeys, during.displayedVisibleKeys)
      assertTrue(during.protectedVisibleKeys.containsAll(before.displayedVisibleKeys))
      assertTrue(during.protectedVisibleKeys.containsAll(during.activeVisibleKeys))

      harness.session.releaseBlockedRender()
      harness.awaitState { !it.transitionPending }
      val after = harness.state()
      assertEquals(after.activeVisibleKeys, after.displayedVisibleKeys)
      assertEquals(after.activeVisibleKeys.toSet(), after.protectedVisibleKeys)
    } finally {
      harness.close()
    }
  }

  @Test
  fun partialLatestCoverageDoesNotSwapDisplayedRequests() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    try {
      val before = harness.state()
      harness.session.renderLimit = 1

      harness.runOnMain {
        harness.controller.setZoomForTest(1.0, PagePoint(2500.0, 2500.0))
      }
      harness.awaitState { it.transitionPending && it.pendingKeys.isEmpty() }
      val after = harness.state()

      assertEquals(before.displayedVisibleKeys, after.displayedVisibleKeys)
      assertTrue(after.transitionPending)
      assertNotEquals(after.activeVisibleKeys, after.displayedVisibleKeys)
    } finally {
      harness.close()
    }
  }

  @Test
  fun alreadyCachedLatestLevelSwapsWithoutWorkerRendering() {
    val harness = ControllerHarness(page = PdfPageDimensions(500.0, 500.0), viewportSize = 64)
    try {
      harness.runOnMain {
        harness.controller.setZoomForTest(0.1, PagePoint(272.0, 272.0))
      }
      harness.awaitState { state ->
        !state.transitionPending && state.activeVisibleKeys.all { key ->
          state.displayedVisibleKeys.contains(key)
        }
      }
      val cachedLevel = harness.state().activeVisibleKeys

      harness.runOnMain {
        harness.controller.setZoomForTest(1.0, PagePoint(272.0, 272.0))
      }
      harness.awaitState { state ->
        !state.transitionPending && state.activeVisibleKeys.all { key ->
          state.displayedVisibleKeys.contains(key)
        }
      }
      val target = harness.state().activeVisibleKeys
      assertNotEquals(cachedLevel, target)
      val renderCountBeforeRestore = harness.session.renderedRequestCount

      harness.runOnMain {
        harness.controller.setZoomForTest(0.1, PagePoint(272.0, 272.0))
      }
      val restored = harness.state()

      assertFalse("cached latest level should swap immediately: $restored", restored.transitionPending)
      assertEquals(restored.activeVisibleKeys, restored.displayedVisibleKeys)
      assertEquals(cachedLevel, restored.activeVisibleKeys)
      assertEquals(renderCountBeforeRestore, harness.session.renderedRequestCount)
    } finally {
      harness.close()
    }
  }

  @Test
  fun rapidLevelChangesKeepNewestTargetAndLastDisplayedLevel() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    try {
      val initial = harness.state()
      val started = harness.session.blockNextRender()
      harness.runOnMain {
        harness.controller.setZoomForTest(1.0, PagePoint(2500.0, 2500.0))
      }
      assertTrue(started.await(5L, TimeUnit.SECONDS))

      harness.runOnMain {
        harness.controller.setZoomForTest(4.0, PagePoint(2500.0, 2500.0))
      }
      val newestTarget = harness.state().activeVisibleKeys
      val during = harness.state()
      assertTrue(during.transitionPending)
      assertEquals(initial.displayedVisibleKeys, during.displayedVisibleKeys)
      assertNotEquals(initial.activeVisibleKeys, newestTarget)

      harness.session.releaseBlockedRender()
      harness.awaitState { !it.transitionPending && it.displayedVisibleKeys == newestTarget }
    } finally {
      harness.close()
    }
  }

  @Test
  fun invalidationClearsHandoffStateAndRecyclesCachedTiles() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    try {
      val started = harness.session.blockNextRender()
      harness.runOnMain {
        harness.controller.setZoomForTest(1.0, PagePoint(2500.0, 2500.0))
      }
      assertTrue(started.await(5L, TimeUnit.SECONDS))

      harness.runOnMain { harness.controller.onDetachedFromWindow() }
      val state = harness.state()

      assertTrue(state.activeVisibleKeys.isEmpty())
      assertTrue(state.activePrefetchKeys.isEmpty())
      assertTrue(state.displayedVisibleKeys.isEmpty())
      assertTrue(state.protectedVisibleKeys.isEmpty())
      assertTrue(state.pendingKeys.isEmpty())
      assertFalse(state.transitionPending)
      assertTrue(harness.session.cachedBitmaps.all(Bitmap::isRecycled))
    } finally {
      harness.close()
    }
  }

  @Test
  fun viewportRequestsPreserveFocusForZoomOnlyAndRefocusExplicitly() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    try {
      harness.runOnMain {
        harness.controller.applyViewport(
          ViewportRequest.FocusAndZoom(
            focus = PagePoint(2500.0, 2500.0),
            zoom = 1.0,
          ),
        )
        harness.controller.applyViewport(
          ViewportRequest.FocusAndZoom(
            focus = null,
            zoom = 2.0,
          ),
        )
      }
      val zoomed = requireNotNull(harness.viewportState())
      assertEquals(2.0, zoomed.zoom, 0.0000001)
      assertEquals(PagePoint(2500.0, 2500.0), zoomed.focus)

      harness.runOnMain {
        harness.controller.applyViewport(
          ViewportRequest.FocusAndZoom(
            focus = PagePoint(1000.0, 1000.0),
            zoom = null,
          ),
        )
      }
      val refocused = requireNotNull(harness.viewportState())
      assertEquals(2.0, refocused.zoom, 0.0000001)
      assertEquals(PagePoint(1000.0, 1000.0), refocused.focus)
    } finally {
      harness.close()
    }
  }

  @Test
  fun enteringTextEditingPreservesZoomAndCentersACaretInAnOversizedEditor() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    try {
      harness.runOnMain {
        harness.controller.applyViewport(
          ViewportRequest.FocusAndZoom(focus = PagePoint(1100.0, 2500.0), zoom = 2.0),
        )
        assertTrue(harness.controller.focusTextForEditing(
          PageRect(4000.0, 3500.0, 4500.0, 3520.0),
          PageRect(4002.0, 3500.0, 4004.0, 3520.0),
          24.0 * context.resources.displayMetrics.density,
        ))
      }
      harness.awaitViewport { kotlin.math.abs(it.focus.x - 4003.0) < 0.001 }
      val settled = requireNotNull(harness.viewportState())
      assertEquals(2.0, settled.zoom, 0.0000001)
      val caretX = settled.pageToView.map(PagePoint(4002.0, 3510.0)).x
      val marginPx = 24.0 * context.resources.displayMetrics.density
      assertTrue(caretX >= marginPx - 0.001 && caretX <= 512.0 - marginPx + 0.001)
    } finally {
      harness.close()
    }
  }

  @Test
  fun currentViewportStateReportsTheConstrainedSnapshotWithoutMutation() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    try {
      harness.runOnMain {
        harness.controller.applyViewport(
          ViewportRequest.FocusAndZoom(
            focus = PagePoint(-100.0, 9_000.0),
            zoom = 2.0,
          ),
        )
      }
      val before = requireNotNull(harness.viewportState())
      val snapshot = harness.captureViewportState()
      val after = requireNotNull(harness.viewportState())

      assertEquals(before, snapshot)
      assertEquals(before, after)
      assertTrue(snapshot.focus.x > 0.0 && snapshot.focus.x < 5_000.0)
      assertTrue(snapshot.focus.y > 0.0 && snapshot.focus.y < 5_000.0)
      assertNotEquals(PagePoint(-100.0, 9_000.0), snapshot.focus)
      assertEquals(2.0, snapshot.zoom, 0.0000001)
    } finally {
      harness.close()
    }
  }

  @Test
  fun currentViewportStateRejectsMissingDocumentAndZeroSizeLayout() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    try {
      harness.runOnMain { harness.controller.onSizeChanged(0, 0) }
      assertEquals("view_not_ready", harness.captureViewportFailure()?.code)

      harness.runOnMain {
        harness.controller.onSizeChanged(512, 512)
        harness.controller.clearDocument()
      }
      assertEquals("view_not_ready", harness.captureViewportFailure()?.code)
    } finally {
      harness.close()
    }
  }

  @Test
  fun pageSwitchFitsAndCentersTargetIncludingRevisits() {
    val firstPage = PdfPageDimensions(5000.0, 5000.0)
    val secondPage = PdfPageDimensions(3000.0, 2000.0)
    val harness = ControllerHarness(
      page = firstPage,
      pages = listOf(firstPage, secondPage),
    )
    try {
      harness.runOnMain {
        harness.controller.setZoomForTest(2.0, PagePoint(900.0, 1_100.0))
      }
      val started = harness.session.blockNextRender()
      harness.runOnMain { harness.switchPage(1) }
      assertTrue(started.await(5L, TimeUnit.SECONDS))
      val target = requireNotNull(harness.viewportState())
      assertEquals(harness.fitZoomFor(secondPage), target.zoom, 0.0000001)
      assertEquals(PagePoint(secondPage.width / 2.0, secondPage.height / 2.0), target.focus)
      val during = harness.state()
      assertTrue(during.activeVisibleKeys.all { it.pageIndex == 1 })

      harness.session.releaseBlockedRender()
      harness.awaitState { it.pendingKeys.isEmpty() }
      assertTrue(harness.session.cachedBitmaps.any { !it.isRecycled })

      harness.runOnMain { harness.switchPage(0) }
      val revisited = harness.captureViewportState()
      assertEquals(harness.fitZoomFor(firstPage), revisited.zoom, 0.0000001)
      assertEquals(PagePoint(firstPage.width / 2.0, firstPage.height / 2.0), revisited.focus)
      assertTrue(harness.state().activeVisibleKeys.all { it.pageIndex == 0 })
    } finally {
      harness.close()
    }
  }

  @Test
  fun doubleTapZoomAnimatesAndEntersEditModeOnlyAfterCompletion() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    val editModeEntries = AtomicInteger(0)
    try {
      harness.runOnMain {
        harness.controller.onDoubleTapEditMode = { editModeEntries.incrementAndGet() }
        harness.controller.setDoubleTapConfiguration(
          DoubleTapOptions(zoom = 2.0, enterEditMode = true),
        )
        harness.sendDoubleTap(256.0f, 256.0f)
      }

      Thread.sleep(40L)
      val during = requireNotNull(harness.viewportState())
      assertTrue(during.zoom > harness.fitZoom())
      assertTrue(during.zoom < 2.0)
      assertEquals(0, editModeEntries.get())

      harness.awaitViewport { it.zoom == 2.0 }
      assertEquals(1, editModeEntries.get())
    } finally {
      harness.close()
    }
  }

  @Test
  fun cancelledDoubleTapZoomDoesNotEnterEditMode() {
    val harness = ControllerHarness(page = PdfPageDimensions(5000.0, 5000.0))
    val editModeEntries = AtomicInteger(0)
    try {
      harness.runOnMain {
        harness.controller.onDoubleTapEditMode = { editModeEntries.incrementAndGet() }
        harness.controller.setDoubleTapConfiguration(
          DoubleTapOptions(zoom = 2.0, enterEditMode = true),
        )
        harness.sendDoubleTap(256.0f, 256.0f)
        harness.sendTouch(MotionEvent.ACTION_DOWN, 256.0f, 256.0f)
      }

      Thread.sleep(250L)
      assertEquals(0, editModeEntries.get())
    } finally {
      harness.close()
    }
  }

  private inner class ControllerHarness(
    private val page: PdfPageDimensions,
    private val pages: List<PdfPageDimensions> = listOf(page),
    private val viewportSize: Int = 512,
  ) {
    private var activePageIndex = 0
    private var pageSwitchId = 1L
    val session = FakeSession(pages)
    private val worker = PdfSessionWorker(opener = FakeSessionOpener(session))
    private val generation = worker.reserveOpenAttemptId(0L)
    lateinit var controller: InkDocumentController
    private val info = PdfSessionInfo("controller-test.pdf", pages, generation)

    init {
      val opened = CountDownLatch(1)
      worker.prepareOpen(generation, "controller-test.pdf", null) { result ->
        assertTrue(result.isSuccess)
        assertTrue(worker.commitPreparedOpen(generation) { committed ->
          assertTrue(committed.isSuccess)
          opened.countDown()
        })
      }
      assertTrue(opened.await(5L, TimeUnit.SECONDS))
      runOnMain {
        controller = InkDocumentController(
          context,
          worker,
          {},
          {},
          currentDocumentGeneration = { generation },
          currentPageIndex = { activePageIndex },
          currentPageSwitchId = { pageSwitchId },
        )
        controller.onSizeChanged(viewportSize, viewportSize)
        controller.setPage(info.pages[0])
      }
      awaitState { !it.transitionPending && it.pendingKeys.isEmpty() }
    }

    fun state(): InkDocumentController.TilePresentationStateForTest {
      var result: InkDocumentController.TilePresentationStateForTest? = null
      instrumentation.runOnMainSync { result = controller.tilePresentationStateForTest() }
      return requireNotNull(result)
    }

    fun viewportState(): PageViewportState? {
      var result: PageViewportState? = null
      instrumentation.runOnMainSync { result = controller.viewportStateForTest() }
      return result
    }

    fun fitZoom(): Double = fitZoomFor(page)

    fun fitZoomFor(page: PdfPageDimensions): Double = PageViewport(
      page,
      ViewportSize(512.0, 512.0, context.resources.displayMetrics.density.toDouble()),
    ).fitZoom()

    fun awaitViewport(predicate: (PageViewportState) -> Boolean) {
      val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5L)
      while (System.nanoTime() < deadline) {
        viewportState()?.let { if (predicate(it)) return }
        Thread.sleep(20L)
      }
      assertTrue("timed out waiting for viewport state", predicate(requireNotNull(viewportState())))
    }

    fun sendDoubleTap(x: Float, y: Float) {
      val now = SystemClock.uptimeMillis()
      sendTouch(MotionEvent.ACTION_DOWN, x, y, now, now)
      sendTouch(MotionEvent.ACTION_UP, x, y, now + 20L, now)
      sendTouch(MotionEvent.ACTION_DOWN, x, y, now + 80L, now + 80L)
      sendTouch(MotionEvent.ACTION_UP, x, y, now + 100L, now + 80L)
    }

    fun sendTouch(
      action: Int,
      x: Float,
      y: Float,
      eventTime: Long = SystemClock.uptimeMillis(),
      downTime: Long = eventTime - 10L,
    ) {
      val event = MotionEvent.obtain(downTime, eventTime, action, x, y, 0)
      try {
        controller.handleViewTouch(event)
      } finally {
        event.recycle()
      }
    }

    fun captureViewportState(): PageViewportState {
      var result: PageViewportState? = null
      instrumentation.runOnMainSync { result = controller.currentViewportState() }
      return requireNotNull(result)
    }

    fun captureViewportFailure(): PdfSessionException? {
      var failure: PdfSessionException? = null
      instrumentation.runOnMainSync {
        try {
          controller.currentViewportState()
        } catch (error: PdfSessionException) {
          failure = error
        }
      }
      return failure
    }

    fun switchPage(index: Int) {
      if (activePageIndex != index) {
        activePageIndex = index
        pageSwitchId += 1L
        controller.setPage(
          dimensions = pages[index],
          fitToPage = true,
        )
      }
    }

    fun runOnMain(action: () -> Unit) {
      instrumentation.runOnMainSync(action)
    }

    fun awaitState(predicate: (InkDocumentController.TilePresentationStateForTest) -> Boolean) {
      val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5L)
      while (System.nanoTime() < deadline) {
        if (predicate(state())) return
        Thread.sleep(20L)
      }
      assertTrue("timed out waiting for tile controller state", predicate(state()))
    }

    fun close() {
      if (::controller.isInitialized) runOnMain { controller.dispose() }
      session.releaseBlockedRender()
      worker.close()
    }
  }

  private class FakeSessionOpener(
    private val session: FakeSession,
  ) : PdfSessionOpener {
    override fun open(path: String, generation: Long): PdfSessionResource = session
  }

  private class FakeSession(
    pages: List<PdfPageDimensions>,
  ) : PdfSessionResource {
    override val info = PdfSessionInfo("controller-test.pdf", pages, 1L)
    val cachedBitmaps = Collections.synchronizedList(ArrayList<Bitmap>())
    @Volatile var renderedRequestCount = 0
      private set
    @Volatile var renderLimit = Int.MAX_VALUE
    @Volatile private var blockNext = false
    @Volatile private var renderStarted: CountDownLatch? = null
    @Volatile private var renderRelease: CountDownLatch? = null

    fun blockNextRender(): CountDownLatch {
      val started = CountDownLatch(1)
      renderStarted = started
      renderRelease = CountDownLatch(1)
      blockNext = true
      return started
    }

    fun releaseBlockedRender() {
      renderRelease?.countDown()
    }

    override fun renderTiles(
      requests: List<PdfTileRequest>,
      beforeEach: () -> Unit,
    ): List<PdfTile> {
      val rendered = ArrayList<PdfTile>()
      try {
        if (blockNext) {
          blockNext = false
          renderStarted?.countDown()
          check(renderRelease?.await(5L, TimeUnit.SECONDS) == true)
        }
        requests.take(renderLimit).forEach { request ->
          beforeEach()
          renderedRequestCount += 1
          val bitmap = Bitmap.createBitmap(
            request.widthPx,
            request.heightPx,
            Bitmap.Config.ARGB_8888,
          )
          cachedBitmaps += bitmap
          rendered += PdfTile(request, bitmap)
        }
        return rendered
      } catch (error: Throwable) {
        rendered.forEach { it.bitmap.recycle() }
        throw error
      }
    }

    override fun renderPreview(
      request: PdfTileRequest,
      beforeRender: () -> Unit,
    ): PdfTile {
      beforeRender()
      throw UnsupportedOperationException("preview is not used by this controller fake")
    }

    override fun close() = Unit
  }
}
