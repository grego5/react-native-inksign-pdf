package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.os.SystemClock
import android.view.MotionEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PageNavigationControllerTest {
  private val harness = ControllerHarness()

  @After
  fun close() = harness.close()

  @Test
  fun outwardStreamForwardsDownThenOneCancelAndStopsOrdinaryRouting() = harness.onMain {
    harness.prepare(SwipeDirection.LEFT)
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    harness.touch(up(-20f, 100f))

    assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL), harness.forwarded)
    assertEquals(1, harness.armed)
    harness.settlement.finishLatest()
    assertEquals(1, harness.installs.size)
  }

  @Test
  fun ordinaryPanRemainsCompleteAndAwayDownNeverTransfers() = harness.onMain {
    listOf(down(150f, 100f), move(130f, 250f), up(130f, 250f)).forEach(harness::touch)
    assertEquals(
      listOf(
        MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP,
      ),
      harness.forwarded,
    )

    harness.focus = PagePoint(175.0, 150.0)
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    assertFalse(harness.controller.state() is NavigationState.Dragging)
    assertEquals(MotionEvent.ACTION_MOVE, harness.forwarded.last())
  }

  @Test
  fun matchingReadyPreviewReplaysArmedPullOnceWhileMissingPreviewDoesNotArm() = harness.onMain {
    harness.controller.reconcilePreviews()
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    assertEquals(0, harness.armed)
    assertNull(harness.controller.presentation().selectedPreview)

    harness.scheduler.complete(SwipeDirection.LEFT)
    assertEquals(1, harness.armed)
    assertTrue(harness.controller.presentation().selectedPreview != null)
    harness.scheduler.complete(SwipeDirection.LEFT)
    assertEquals(1, harness.armed)
  }

  @Test
  fun matchingPreviewFailureRetriesOnTheNextEligibleGestureAndEnablesNavigation() = harness.onMain {
    harness.controller.reconcilePreviews()
    val requestCountBeforeFailure = harness.scheduler.requestCount(SwipeDirection.LEFT)
    harness.scheduler.fail(SwipeDirection.LEFT)
    assertFalse(harness.controller.previewDirections().contains(SwipeDirection.LEFT))

    harness.touch(down(150f, 100f))
    assertEquals(requestCountBeforeFailure + 1, harness.scheduler.requestCount(SwipeDirection.LEFT))
    harness.scheduler.complete(SwipeDirection.LEFT)
    harness.touch(move(0f, 100f))
    harness.touch(up(0f, 100f))
    harness.settlement.finishLatest()

    assertTrue(harness.controller.state() is NavigationState.Switching)
  }

  @Test
  fun stalePreviewIsRecycledAndReplacingOneDirectionKeepsTheOther() = harness.onMain {
    harness.controller.reconcilePreviews()
    val stale = harness.scheduler.pending(SwipeDirection.LEFT)
    harness.scheduler.complete(SwipeDirection.RIGHT)
    harness.controller.cancel()
    stale.complete()
    assertTrue(stale.bitmap!!.isRecycled)

    harness.controller.reconcilePreviews()
    harness.scheduler.complete(SwipeDirection.LEFT)
    harness.scheduler.complete(SwipeDirection.RIGHT)
    assertEquals(setOf(SwipeDirection.LEFT, SwipeDirection.RIGHT), harness.controller.previewDirections())
    harness.revisionByPage[2] = 1L
    harness.controller.reconcilePreviews()
    assertTrue(harness.controller.previewDirections().contains(SwipeDirection.RIGHT))
  }

  @Test
  fun falseInstallationReturnsIdleReconcilesAndAllowsTheNextSwipe() = harness.onMain {
    harness.prepare(SwipeDirection.LEFT)
    harness.installResult = false
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    val failedPreview = requireNotNull(harness.controller.presentation().selectedPreview)
    harness.touch(up(0f, 100f))
    harness.settlement.finishLatest()
    assertEquals(NavigationState.Idle, harness.controller.state())
    assertTrue(harness.settled > 0)
    assertEquals(failedPreview.request.key, harness.installs.single().previewKey)

    harness.scheduler.complete(SwipeDirection.LEFT)
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    val replacementPreview = requireNotNull(harness.controller.presentation().selectedPreview)
    assertEquals(failedPreview.request.key, replacementPreview.request.key)
    assertFalse(failedPreview.bitmap === replacementPreview.bitmap)

    harness.installResult = true
    harness.touch(up(0f, 100f))
    harness.settlement.finishLatest()
    assertTrue(harness.controller.state() is NavigationState.Switching)
    assertEquals(replacementPreview.request.key, harness.installs.last().previewKey)
  }

  @Test
  fun recoverableInstallationExceptionReturnsIdleAndAllowsTheNextSwipe() = harness.onMain {
    harness.prepare(SwipeDirection.LEFT)
    harness.installException = PdfSessionException("test_install", "controlled failure")
    harness.swipeLeftAndRelease()
    harness.settlement.finishLatest()

    assertEquals(NavigationState.Idle, harness.controller.state())
    assertTrue(harness.settled > 0)

    harness.installException = null
    harness.scheduler.complete(SwipeDirection.LEFT)
    harness.swipeLeftAndRelease()
    harness.settlement.finishLatest()
    assertTrue(harness.controller.state() is NavigationState.Switching)
  }

  @Test
  fun subthresholdReleaseKeepsPreviewThroughSnapBackThenReturnsToUsableIdle() = harness.onMain {
    harness.prepare(SwipeDirection.LEFT)
    harness.touch(down(150f, 100f))
    harness.touch(move(80f, 100f))
    val preview = requireNotNull(harness.controller.presentation().selectedPreview)

    harness.touch(up(80f, 100f))
    assertTrue(harness.controller.state() is NavigationState.Settling)
    assertSame(preview, harness.controller.presentation().selectedPreview)

    harness.settlement.finishLatest()
    assertEquals(NavigationState.Idle, harness.controller.state())
    assertNull(harness.controller.presentation().selectedPreview)
    assertEquals(0.0, harness.controller.presentation().translationX, 0.0001)
    assertEquals(1.0, harness.controller.presentation().currentPageScale, 0.0001)

    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    assertTrue(harness.controller.state() is NavigationState.Dragging)
    assertSame(preview, harness.controller.presentation().selectedPreview)
  }

  @Test
  fun onlyMatchingTileIdentityFinishesSwitchAndDelayedCallbacksAreNoops() = harness.onMain {
    harness.prepare(SwipeDirection.LEFT)
    harness.swipeLeftAndRelease()
    harness.settlement.finishLatest()
    val handoff = harness.installs.single()
    harness.controller.onVisibleTilesReady(9L, handoff.targetPageIndex, handoff.pageSwitchId)
    assertTrue(harness.controller.state() is NavigationState.Switching)
    harness.controller.onVisibleTilesFailed(1L, handoff.targetPageIndex, handoff.pageSwitchId - 1L)
    assertTrue(harness.controller.state() is NavigationState.Switching)
    harness.controller.onVisibleTilesFailed(1L, handoff.targetPageIndex, handoff.pageSwitchId)
    assertEquals(NavigationState.Idle, harness.controller.state())

    harness.controller.cancel()
    harness.controller.onVisibleTilesReady(1L, handoff.targetPageIndex, handoff.pageSwitchId)
    assertEquals(NavigationState.Idle, harness.controller.state())
  }

  @Test
  fun panelsUseTheSameViewportSizedFrame() = harness.onMain {
    harness.width = 480
    harness.height = 280
    harness.prepare(SwipeDirection.LEFT)
    harness.touch(down(240f, 100f))
    harness.touch(move(0f, 100f))
    val beforeRelease = harness.controller.presentation().selectedPreview
    harness.touch(up(0f, 100f))
    assertSame(beforeRelease, harness.controller.presentation().selectedPreview)
    val presentation = harness.controller.presentation()
    assertEquals(480.0 + presentation.translationX, presentation.targetPanelOffsetX, 0.0001)
    assertEquals(480, requireNotNull(beforeRelease).request.request.widthPx)
    assertEquals(280, beforeRelease.request.request.heightPx)
    harness.settlement.finishLatest()
    assertTrue(harness.controller.state() is NavigationState.Switching)
  }

  private class ControllerHarness {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val worker = PdfSessionWorker(PdfSessionOpener { _, _ -> error("unused") })
    val scheduler = ManualPreviewScheduler()
    val settlement = ManualSettlementDriver()
    val forwarded = ArrayList<Int>()
    val installs = ArrayList<PageSwitchHandoff>()
    val revisionByPage = hashMapOf(0 to 0L, 1 to 0L, 2 to 0L)
    var armed = 0
    var settled = 0
    var installResult = true
    var installException: PdfSessionException? = null
    var width = 300
    var height = 300
    var focus = PagePoint(150.0, 150.0)
    val controller = PageNavigationController(
      sessionWorker = worker,
      requestInvalidate = {},
      requestAnimation = {},
      currentContext = ::context,
      currentViewportState = { viewport() },
      targetPage = { PdfPageDimensions(300.0, 500.0) },
      targetInkPaths = { emptyList() },
      targetTextAnnotations = { emptyList() },
      fitZoomFor = { 1.0 },
      previewPreparationAllowed = { true },
      installCommittedPage = {
        installs += it
        installException?.let { exception -> throw exception }
        installResult
      },
      forwardToDocumentNavigation = { forwarded += it.actionMasked },
      onArmed = { armed += 1 },
      onPageNavigationSettled = { settled += 1 },
      previewScheduler = scheduler,
      settlementDriver = settlement,
    )

    fun onMain(action: () -> Unit) = instrumentation.runOnMainSync(action)

    fun prepare(direction: SwipeDirection) {
      controller.reconcilePreviews()
      scheduler.complete(direction)
    }

    fun touch(event: MotionEvent) {
      if (!controller.onTouch(event)) forwarded += event.actionMasked
      event.recycle()
    }

    fun swipeLeftAndRelease() {
      touch(down(150f, 100f))
      touch(move(0f, 100f))
      touch(up(0f, 100f))
    }

    fun close() = worker.close()

    private fun context() = NavigationContext(
      documentGeneration = 1L,
      sourcePageIndex = 1,
      pageCount = 3,
      pageSwitchId = 4L,
      viewportWidthPx = width,
      viewportHeightPx = height,
      density = 1.0,
      layoutDirection = android.view.View.LAYOUT_DIRECTION_LTR,
      eligibleTargets = mapOf(SwipeDirection.LEFT to 2, SwipeDirection.RIGHT to 0),
      targetContentRevisions = revisionByPage,
    )

    private fun viewport(): PageViewportState {
      val transform = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
      return PageViewportState(1.0, focus, transform, transform)
    }
  }

  private class ManualPreviewScheduler : PageNavigationPreviewScheduler {
    data class Pending(
      val request: PdfTileRequest,
      val completion: (Result<PdfTile>) -> Unit,
      var bitmap: Bitmap? = null,
    ) {
      fun complete() {
        bitmap = Bitmap.createBitmap(request.widthPx, request.heightPx, Bitmap.Config.ARGB_8888)
        completion(Result.success(PdfTile(request, bitmap!!)))
      }
    }

    private val requests = ArrayList<Pending>()
    override fun updateEpoch(generation: Long, previewEpoch: Long) = Unit
    override fun renderPreview(generation: Long, previewEpoch: Long, request: PdfTileRequest,
      completion: (Result<PdfTile>) -> Unit) { requests += Pending(request, completion) }
    fun fail(direction: SwipeDirection) = pending(direction).completion(Result.failure(
      IllegalStateException("controlled preview failure"),
    ))
    fun requestCount(direction: SwipeDirection): Int = requests.count {
      it.request.key.pageIndex == if (direction == SwipeDirection.LEFT) 2 else 0
    }
    fun pending(direction: SwipeDirection): Pending = requests.last {
      it.request.key.pageIndex == if (direction == SwipeDirection.LEFT) 2 else 0
    }
    fun complete(direction: SwipeDirection) = pending(direction).complete()
  }

  private class ManualSettlementDriver : PageNavigationSettlementDriver {
    private data class Pending(val onEnd: () -> Unit) : PageNavigationSettlementDriver.Handle {
      override fun cancel() = Unit
    }
    private val pending = ArrayList<Pending>()
    override fun start(from: Float, to: Float, durationMillis: Long, onProgress: (Float) -> Unit,
      onEnd: () -> Unit): PageNavigationSettlementDriver.Handle = Pending(onEnd).also(pending::add)
    fun finishLatest() = pending.removeLast().onEnd()
  }

  private companion object {
    fun event(action: Int, x: Float, y: Float, pointers: Int = 1): MotionEvent {
      val now = SystemClock.uptimeMillis()
      if (pointers == 1) return MotionEvent.obtain(now, now, action, x, y, 0)
      val properties = Array(pointers) { MotionEvent.PointerProperties() }
      val coordinates = Array(pointers) { MotionEvent.PointerCoords().apply { this.x = x; this.y = y } }
      properties.forEachIndexed { index, property -> property.id = index }
      return MotionEvent.obtain(now, now, action, pointers, properties, coordinates, 0, 0, 1f, 1f, 0, 0, 0, 0)
    }
    fun down(x: Float, y: Float) = event(MotionEvent.ACTION_DOWN, x, y)
    fun move(x: Float, y: Float, pointers: Int = 1) = event(MotionEvent.ACTION_MOVE, x, y, pointers)
    fun up(x: Float, y: Float) = event(MotionEvent.ACTION_UP, x, y)
  }
}
