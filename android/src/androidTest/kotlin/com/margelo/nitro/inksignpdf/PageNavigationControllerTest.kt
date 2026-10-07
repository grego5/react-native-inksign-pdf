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
  fun returningToOriginKeepsPullActiveAndAllowsEitherNeighbor() = harness.onMain {
    harness.scheduler.completeImmediately = true
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    assertEquals(SwipeDirection.LEFT, harness.controller.presentation().direction)
    harness.touch(move(150f, 100f))
    assertTrue(harness.controller.state() is NavigationState.Dragging)
    assertEquals(null, harness.controller.presentation().selectedPreview)
    harness.touch(move(0f, 100f))
    assertEquals(SwipeDirection.LEFT, harness.controller.presentation().direction)
    harness.touch(move(150f, 100f))
    harness.touch(move(300f, 100f))
    assertEquals(SwipeDirection.RIGHT, harness.controller.presentation().direction)
    harness.touch(up(300f, 100f))
    harness.settlement.finishLatest()
    assertEquals(0, harness.installs.single().targetPageIndex)
    assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL), harness.forwarded)
  }

  @Test
  fun outwardStreamForwardsDownThenOneCancelAndStopsOrdinaryRouting() = harness.onMain {
    harness.scheduler.completeImmediately = true
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
    harness.touch(down(150f, 100f))
    assertEquals(0, harness.scheduler.requestCount(SwipeDirection.LEFT))
    assertEquals(0, harness.scheduler.requestCount(SwipeDirection.RIGHT))
    harness.touch(move(0f, 100f))
    assertEquals(0, harness.armed)
    assertNull(harness.controller.presentation().selectedPreview)
    assertTrue(harness.controller.presentation().translationX < 0.0)

    harness.scheduler.complete(SwipeDirection.LEFT)
    assertEquals(1, harness.armed)
    assertTrue(harness.controller.presentation().selectedPreview != null)
    harness.scheduler.complete(SwipeDirection.LEFT)
    assertEquals(1, harness.armed)
  }

  @Test
  fun matchingPreviewFailureRetriesOnTheNextEligibleGestureAndEnablesNavigation() = harness.onMain {
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    val requestCountBeforeFailure = harness.scheduler.requestCount(SwipeDirection.LEFT)
    harness.touch(up(0f, 100f))
    harness.scheduler.fail(SwipeDirection.LEFT)
    assertFalse(harness.controller.previewDirections().contains(SwipeDirection.LEFT))
    assertTrue(harness.controller.state() is NavigationState.Settling)
    harness.settlement.finishLatest()

    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    assertEquals(
      requestCountBeforeFailure + 1,
      harness.scheduler.requestCount(SwipeDirection.LEFT),
    )
    harness.scheduler.complete(SwipeDirection.LEFT)
    harness.touch(up(0f, 100f))
    harness.settlement.finishLatest()

    assertTrue(harness.controller.handoffPending())
  }

  @Test
  fun stalePreviewIsRecycledWithoutReplacingTheCurrentRequest() = harness.onMain {
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    val stale = harness.scheduler.pending(SwipeDirection.LEFT)
    harness.controller.reset()
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    stale.complete()
    assertTrue(stale.bitmap!!.isRecycled)
    assertNull(harness.controller.presentation().selectedPreview)
    harness.scheduler.complete(SwipeDirection.LEFT)
    assertEquals(setOf(SwipeDirection.LEFT), harness.controller.previewDirections())
  }

  @Test
  fun falseInstallationReturnsIdleAndAllowsTheNextSwipe() = harness.onMain {
    harness.scheduler.completeImmediately = true
    harness.installResult = false
    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    val failedPreview = requireNotNull(harness.controller.presentation().selectedPreview)
    harness.touch(up(0f, 100f))
    harness.settlement.finishLatest()
    assertEquals(NavigationState.Idle, harness.controller.state())
    assertTrue(harness.settled > 0)
    assertEquals(failedPreview.request.key, harness.installs.single().previewKey)

    harness.touch(down(150f, 100f))
    harness.touch(move(0f, 100f))
    val replacementPreview = requireNotNull(harness.controller.presentation().selectedPreview)
    assertEquals(failedPreview.request.key, replacementPreview.request.key)
    assertFalse(failedPreview.bitmap === replacementPreview.bitmap)

    harness.installResult = true
    harness.touch(up(0f, 100f))
    harness.settlement.finishLatest()
    assertTrue(harness.controller.handoffPending())
    assertEquals(replacementPreview.request.key, harness.installs.last().previewKey)
  }

  @Test
  fun recoverableInstallationExceptionReturnsIdleAndAllowsTheNextSwipe() = harness.onMain {
    harness.scheduler.completeImmediately = true
    harness.installException = PdfSessionException("test_install", "controlled failure")
    harness.swipeLeftAndRelease()
    harness.settlement.finishLatest()

    assertEquals(NavigationState.Idle, harness.controller.state())
    assertTrue(harness.settled > 0)

    harness.installException = null
    harness.swipeLeftAndRelease()
    harness.settlement.finishLatest()
    assertTrue(harness.controller.handoffPending())
  }

  @Test
  fun subthresholdReleaseKeepsPreviewThroughSnapBackThenReturnsToUsableIdle() = harness.onMain {
    harness.scheduler.completeImmediately = true
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
    assertTrue(preview.bitmap.isRecycled)
    assertTrue(harness.controller.presentation().selectedPreview != null)
  }

  @Test
  fun newDownCompletesCommittedSwitchAndIgnoresOldCompletion() = harness.onMain {
    harness.scheduler.completeImmediately = true
    harness.swipeLeftAndRelease()
    harness.settlement.advanceLatest(0.5f)
    assertTrue(harness.controller.presentation().translationX != 0.0)
    harness.touch(down(150f, 100f))
    assertTrue(harness.controller.state() is NavigationState.Dragging)
    assertEquals(0.0, harness.controller.presentation().translationX, 0.0)
    harness.settlement.finishLatest()
    assertEquals(1, harness.installs.size)
    val context = (harness.controller.state() as NavigationState.Dragging).transaction.context
    assertEquals(harness.installs.single().targetPageIndex, context.sourcePageIndex)
    assertEquals(harness.installs.single().pageSwitchId, context.pageSwitchId)
    harness.touch(move(270f, 100f))
    assertTrue(harness.controller.presentation().translationX > 0.0)
  }

  @Test
  fun newDownDuringRestKeepsCurrentPageAndStartsAnotherPull() = harness.onMain {
    harness.scheduler.completeImmediately = true
    harness.touch(down(150f, 100f))
    harness.touch(move(80f, 100f))
    harness.touch(up(80f, 100f))
    harness.settlement.advanceLatest(0.5f)
    harness.touch(down(150f, 100f))
    harness.settlement.finishLatest()
    assertTrue(harness.installs.isEmpty())
    assertTrue(harness.controller.state() is NavigationState.Dragging)
    harness.touch(move(0f, 100f))
    assertTrue(harness.controller.presentation().translationX < 0.0)
  }

  @Test
  fun newPullDuringTileHandoffKeepsFallbackAndSurvivesItsAcknowledgement() = harness.onMain {
    harness.scheduler.completeImmediately = true
    harness.swipeLeftAndRelease()
    harness.settlement.finishLatest()
    val handoff = harness.installs.single()
    val fallback = requireNotNull(harness.controller.presentation().currentPagePreview)
    harness.touch(down(150f, 100f))
    assertTrue(harness.controller.state() is NavigationState.Dragging)
    assertSame(fallback, harness.controller.presentation().currentPagePreview)
    assertFalse(fallback.bitmap.isRecycled)
    harness.touch(move(270f, 100f))
    val drag = harness.controller.state()
    val context = (drag as NavigationState.Dragging).transaction.context
    assertEquals(handoff.targetPageIndex, context.sourcePageIndex)
    assertEquals(handoff.pageSwitchId, context.pageSwitchId)
    assertEquals(handoff.sourcePageIndex, context.eligibleTargets[SwipeDirection.RIGHT])
    assertTrue(harness.controller.presentation().translationX > 0.0)
    harness.controller.onVisibleTilesPresented(1L, handoff.targetPageIndex, handoff.pageSwitchId)
    assertEquals(drag, harness.controller.state())
    assertFalse(harness.controller.handoffPending())
    assertTrue(fallback.bitmap.isRecycled)
    harness.touch(up(270f, 100f))
    harness.settlement.finishLatest()
    val nextHandoff = harness.installs.last()
    assertEquals(handoff.targetPageIndex, nextHandoff.sourcePageIndex)
    assertEquals(handoff.sourcePageIndex, nextHandoff.targetPageIndex)
    assertEquals(handoff.pageSwitchId + 1L, nextHandoff.pageSwitchId)
  }

  @Test
  fun onlyMatchingTileIdentityFinishesSwitchAndDelayedCallbacksAreNoops() = harness.onMain {
    harness.scheduler.completeImmediately = true
    harness.swipeLeftAndRelease()
    harness.settlement.finishLatest()
    val handoff = harness.installs.single()
    harness.controller.onVisibleTilesPresented(9L, handoff.targetPageIndex, handoff.pageSwitchId)
    assertTrue(harness.controller.handoffPending())
    harness.controller.onVisibleTilesFailed(1L, handoff.targetPageIndex, handoff.pageSwitchId - 1L)
    assertTrue(harness.controller.handoffPending())
    harness.controller.onVisibleTilesFailed(1L, handoff.targetPageIndex, handoff.pageSwitchId)
    assertTrue(harness.controller.handoffPending())
    assertEquals(NavigationState.Idle, harness.controller.state())

    harness.controller.reset()
    harness.controller.onVisibleTilesPresented(1L, handoff.targetPageIndex, handoff.pageSwitchId)
    assertEquals(NavigationState.Idle, harness.controller.state())
  }

  @Test
  fun panelsUseTheSameViewportSizedFrame() = harness.onMain {
    harness.width = 480
    harness.height = 280
    harness.scheduler.completeImmediately = true
    harness.touch(down(240f, 100f))
    harness.touch(move(0f, 100f))
    val beforeRelease = harness.controller.presentation().selectedPreview
    harness.touch(up(0f, 100f))
    assertSame(beforeRelease, harness.controller.presentation().selectedPreview)
    val presentation = harness.controller.presentation()
    assertEquals(480.0 + presentation.translationX, presentation.targetPanelOffsetX, 0.0001)
    val raster = requireNotNull(beforeRelease).request.request
    assertEquals(pageBaseLongestEdgePx, maxOf(raster.widthPx, raster.heightPx))
    assertEquals(300.0 / 500.0, raster.widthPx.toDouble() / raster.heightPx, 0.001)
    assertEquals(0, raster.leftPx)
    assertEquals(0, raster.topPx)
    harness.settlement.finishLatest()
    assertTrue(harness.controller.handoffPending())
  }

  private class ControllerHarness {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private var sourcePageIndex = 1
    private var pageSwitchId = 4L
    val scheduler = ManualPreviewScheduler { direction ->
      sourcePageIndex + if (direction == SwipeDirection.LEFT) 1 else -1
    }
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
        if (installResult) {
          sourcePageIndex = it.targetPageIndex
          pageSwitchId = it.pageSwitchId
          focus = PagePoint(150.0, 250.0)
        }
        installResult
      },
      forwardToDocumentNavigation = { forwarded += it.actionMasked },
      onArmed = { armed += 1 },
      onPageNavigationSettled = { settled += 1 },
      previewScheduler = scheduler,
      settlementDriver = settlement,
    )

    fun onMain(action: () -> Unit) = instrumentation.runOnMainSync(action)

    fun touch(event: MotionEvent) {
      if (!controller.onTouch(event)) forwarded += event.actionMasked
      event.recycle()
    }

    fun swipeLeftAndRelease() {
      touch(down(150f, 100f))
      touch(move(0f, 100f))
      touch(up(0f, 100f))
    }

    fun close() = onMain { controller.reset() }

    private fun context() = NavigationContext(
      documentGeneration = 1L,
      sourcePageIndex = sourcePageIndex,
      pageCount = 3,
      pageSwitchId = pageSwitchId,
      viewportWidthPx = width,
      viewportHeightPx = height,
      density = 1.0,
      layoutDirection = android.view.View.LAYOUT_DIRECTION_LTR,
      eligibleTargets = buildMap {
        if (sourcePageIndex < 2) put(SwipeDirection.LEFT, sourcePageIndex + 1)
        if (sourcePageIndex > 0) put(SwipeDirection.RIGHT, sourcePageIndex - 1)
      },
      targetContentRevisions = revisionByPage,
    )

    private fun viewport(): PageViewportState {
      val transform = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
      return PageViewportState(1.0, focus, transform, transform)
    }
  }

  private class ManualPreviewScheduler(
    private val targetPageIndex: (SwipeDirection) -> Int,
  ) : PageNavigationPreviewScheduler {
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
    var completeImmediately = false
    override fun renderPreview(generation: Long, request: PdfTileRequest,
      completion: (Result<PdfTile>) -> Unit) {
      val pending = Pending(request, completion)
      requests += pending
      if (completeImmediately) pending.complete()
    }
    fun fail(direction: SwipeDirection) = pending(direction).completion(Result.failure(
      IllegalStateException("controlled preview failure"),
    ))
    fun requestCount(direction: SwipeDirection): Int = requests.count {
      it.request.key.pageIndex == targetPageIndex(direction)
    }
    fun pending(direction: SwipeDirection): Pending = requests.last {
      it.request.key.pageIndex == targetPageIndex(direction)
    }
    fun complete(direction: SwipeDirection) = pending(direction).complete()
  }

  private class ManualSettlementDriver : PageNavigationSettlementDriver {
    private data class Pending(val onProgress: (Float) -> Unit, val onEnd: () -> Unit) : PageNavigationSettlementDriver.Handle {
      override fun cancel() = Unit
    }
    private val pending = ArrayList<Pending>()
    override fun start(from: Float, to: Float, durationMillis: Long, onProgress: (Float) -> Unit,
      onEnd: () -> Unit): PageNavigationSettlementDriver.Handle = Pending(onProgress, onEnd).also(pending::add)
    fun advanceLatest(amount: Float) = pending.last().onProgress(amount)
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
