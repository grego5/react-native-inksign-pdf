package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SurfaceViewTest {
  private lateinit var harness: SurfaceHarness

  @Before
  fun setUp() {
    NativeTestRuntime.initialize()
    harness = SurfaceHarness()
  }

  @After
  fun tearDown() {
    if (::harness.isInitialized) {
      harness.close()
    }
    FakePdfSession.resetControls()
  }

  @Test
  fun surfaceSwitchesPagesWithoutChangingDocumentGeneration() {
    var first: PdfPageInfo? = null
    var second: PdfPageInfo? = null
    var restored: PdfPageInfo? = null
    var generation = 0L
    harness.runOnMain {
      first = harness.surface.currentPageInfo()
      generation = harness.surface.currentDocumentInfo().generation
      second = harness.surface.switchPage(1)
      restored = harness.surface.switchPage(0)
    }

    assertEquals(0, requireNotNull(first).pageIndex)
    assertEquals(3, requireNotNull(first).pageCount)
    assertEquals(1, requireNotNull(second).pageIndex)
    assertEquals(PdfPageDimensions(600.0, 700.0), requireNotNull(second).dimensions)
    assertEquals(0, requireNotNull(restored).pageIndex)
    harness.runOnMain {
      assertEquals(generation, harness.surface.currentDocumentInfo().generation)
    }
  }

  @Test
  fun pageSwitchFitsAndCentersEveryTarget() {
    val info = harness.documentInfo()
    val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density.toDouble()
    fun fitZoom(page: PdfPageDimensions) = PageViewport(
      page, ViewportSize(300.0, 300.0, density),
    ).fitZoom()

    harness.runOnMain {
      harness.setDocument(
        info,
        zoom = 2.0,
        focus = PagePoint(120.0, 140.0),
        fitToPage = false,
      )
      harness.surface.switchPage(1)
      val target = harness.surface.currentViewportState()
      assertEquals(fitZoom(info.pages[1]), target.zoom, 0.0000001)
      assertEquals(PagePoint(300.0, 350.0), target.focus)

      harness.surface.switchPage(0)
      val revisited = harness.surface.currentViewportState()
      assertEquals(fitZoom(info.pages[0]), revisited.zoom, 0.0000001)
      assertEquals(PagePoint(150.0, 150.0), revisited.focus)
    }
  }

  @Test
  fun pageSwitchesCoverMiddleAndLastPagesAndBoundaryNoOps() {
    var middle: PdfPageInfo? = null
    var last: PdfPageInfo? = null
    var nextBoundary: PdfPageInfo? = null
    var firstBoundary: PdfPageInfo? = null
    harness.runOnMain {
      middle = harness.surface.switchPage(1)
      last = harness.surface.switchPage(2)
      nextBoundary = harness.surface.switchPage(2)
      firstBoundary = harness.surface.switchPage(0)
    }

    assertEquals(1, requireNotNull(middle).pageIndex)
    assertEquals(2, requireNotNull(last).pageIndex)
    assertEquals(2, requireNotNull(nextBoundary).pageIndex)
    assertEquals(0, requireNotNull(firstBoundary).pageIndex)
  }

  @Test
  fun stableLayoutPrewarmsAdjacentPreviewBeforeTouchMovement() {
    harness.awaitPreparedPagePreview()

    harness.runOnMain {
      val state = harness.surface.pageNavigationState()
      assertTrue(state.preparedDirections.contains(SwipeDirection.LEFT))
      assertFalse(state.previewPresented)
    }
  }

  @Test
  fun selectedPreviewGatesPullAndReleaseUntilItIsReady() {
    FakePdfSession.holdPreviews()
    harness.runOnMain { harness.setDocument(harness.documentInfo()) }
    assertTrue(
      "preview rendering must be held before sending the gated gesture",
      FakePdfSession.awaitPreviewStarted(),
    )
    harness.sendPageNavigationSwipe()

    harness.sendPageNavigationRelease()

    harness.runOnMain {
      assertEquals(0, harness.surface.currentPageInfo().pageIndex)
      assertFalse(harness.surface.pageNavigationState().previewPresented)
    }
    FakePdfSession.releasePreviews()
    harness.runOnMain {
      assertEquals(0, harness.surface.currentPageInfo().pageIndex)
      assertFalse(harness.surface.pageNavigationState().handoffPending)
    }
  }

  @Test
  fun readyPreviewReplaysAnArmedPullAndEmitsFeedbackOnce() {
    val previewScheduler = ManualPreviewScheduler()
    harness.close()
    harness = SurfaceHarness(previewScheduler = previewScheduler)
    assertTrue(previewScheduler.awaitRequest())
    harness.sendPageNavigationSwipe()

    previewScheduler.completeLatest()
    harness.runOnMain {
      assertTrue(harness.surface.pageNavigationState().previewPresented)
    }
  }

  @Test
  fun inwardDragAtNavigableBoundaryRemainsOrdinaryViewportNavigation() {
    harness.runOnMain {
      harness.setDocument(
        harness.documentInfo(),
        zoom = 2.0,
        focus = PagePoint(300.0, 150.0),
        fitToPage = false,
      )
      val before = harness.surface.currentViewportState()
      dispatch(downEvent(150.0f, 150.0f, 12_000L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 230.0f, 150.0f, 12_020L))
      dispatch(upEvent(230.0f, 150.0f, 12_040L))

      assertEquals(0, harness.surface.currentPageInfo().pageIndex)
      assertTrue(harness.surface.currentViewportState().focus.x < before.focus.x)
      assertEquals(NavigationState.Idle, harness.surface.pageNavigationState().state)
    }
  }

  @Test
  fun winningSwipeTransfersOnceAndProcessesLaterUpAsPageNavigation() {
    harness.awaitPreparedPagePreview()
    val callbackCount = AtomicReference(0)
    harness.runOnMain {
      harness.surface.onPageChange = { callbackCount.set(callbackCount.get() + 1) }
      dispatch(downEvent(150.0f, 150.0f, 13_000L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 0.0f, 150.0f, 13_020L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, -20.0f, 150.0f, 13_030L))
      dispatch(upEvent(-20.0f, 150.0f, 13_040L))

    }

    harness.awaitPage { it == 1 }
    assertEquals(1, callbackCount.get())
  }

  @Test
  fun belowThresholdTransferredSwipeSnapsBackWithoutSwitching() {
    val driver = ManualSettlementDriver()
    harness.close()
    harness = SurfaceHarness(settlementDriver = driver)
    harness.awaitPreparedPagePreview()
    val density = InstrumentationRegistry.getInstrumentation().targetContext
      .resources.displayMetrics.density
    val dragDistance = 8.0f * density + 1.0f
    harness.runOnMain {
      dispatch(downEvent(150.0f, 150.0f, 14_000L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 150.0f - dragDistance, 150.0f, 14_020L))
      assertTrue(harness.surface.pageNavigationState().state is NavigationState.Dragging)
      assertTrue(harness.surface.pageNavigationState().previewPresented)
      dispatch(upEvent(150.0f - dragDistance, 150.0f, 14_040L))

      assertEquals(0, harness.surface.currentPageInfo().pageIndex)
      assertTrue(harness.surface.pageNavigationState().state is NavigationState.Settling)
      assertEquals(1, driver.pendingCount())
      assertTrue(harness.surface.pageNavigationState().previewPresented)

      driver.finish(0)
      assertEquals(NavigationState.Idle, harness.surface.pageNavigationState().state)
      assertFalse(harness.surface.pageNavigationState().previewPresented)
    }
  }

  @Test
  fun armedFeedbackFiresOnceAcrossGradualAndContinuedArmedMoves() {
    harness.awaitPreparedPagePreview()
    harness.runOnMain {
      dispatch(downEvent(150.0f, 150.0f, 15_000L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 130.0f, 150.0f, 15_020L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 100.0f, 150.0f, 15_030L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 0.0f, 150.0f, 15_040L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, -40.0f, 150.0f, 15_050L))
      dispatch(upEvent(-40.0f, 150.0f, 15_060L))

    }
    harness.awaitPage { it == 1 }
  }

  @Test
  fun newDownDuringSnapBackInvalidatesLateSettlementCallback() {
    val driver = ManualSettlementDriver()
    harness.close()
    harness = SurfaceHarness(settlementDriver = driver)
    harness.awaitPreparedPagePreview()
    val density = InstrumentationRegistry.getInstrumentation().targetContext
      .resources.displayMetrics.density
    val dragDistance = 8.0f * density + 1.0f

    harness.runOnMain {
      dispatch(downEvent(150.0f, 150.0f, 16_000L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 150.0f - dragDistance, 150.0f, 16_020L))
      dispatch(upEvent(150.0f - dragDistance, 150.0f, 16_040L))
      assertEquals(NavigationState.Settling::class, harness.surface.pageNavigationState().state::class)
      assertEquals(1, driver.pendingCount())

      dispatch(downEvent(150.0f, 150.0f, 16_060L))
      assertTrue(harness.surface.pageNavigationState().state is NavigationState.Dragging)
      driver.finish(0)
      assertTrue(harness.surface.pageNavigationState().state is NavigationState.Dragging)

      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 0.0f, 150.0f, 16_080L))
      dispatch(upEvent(0.0f, 150.0f, 16_100L))
      assertEquals(2, driver.pendingCount())
      driver.finish(1)
    }

    harness.awaitPage { it == 1 }
  }

  @Test
  fun leavingEditModeResumesPreviewPreparationForPageNavigation() {
    harness.awaitPreparedPagePreview()
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(80.0f, 100.0f, 20_000L))
      dispatch(upEvent(180.0f, 100.0f, 20_020L))
      harness.surface.setEditMode(false)
    }
    harness.awaitPreparedPagePreview()
    harness.sendPageNavigationSwipe()
    harness.sendPageNavigationRelease()
    harness.awaitPage { it == 1 }
  }

  @Test
  fun regainingWindowFocusResumesPreviewPreparationForPageNavigation() {
    harness.awaitPreparedPagePreview()
    harness.runOnMain {
      harness.surface.onWindowFocusChanged(false)
      harness.surface.onWindowFocusChanged(true)
    }
    harness.awaitPreparedPagePreview()
    harness.sendPageNavigationSwipe()
    harness.sendPageNavigationRelease()
    harness.awaitPage { it == 1 }
  }

  @Test
  fun resumingWithValidCoverageDoesNotDuplicatePreviewJobs() {
    harness.awaitPreparedPagePreview()
    val renderCount = FakePdfSession.previewRenderCount
    harness.runOnMain {
      harness.surface.onWindowFocusChanged(true)
      harness.surface.onWindowFocusChanged(true)
    }
    harness.awaitWorkerIdle()
    assertEquals(renderCount, FakePdfSession.previewRenderCount)
  }

  @Test
  fun armedHandoffRetainsPreviewUntilDelayedTargetTilesAreReady() {
    harness.awaitPreparedPagePreview()
    val callbackCount = AtomicReference(0)
    harness.runOnMain { harness.surface.onPageChange = { callbackCount.set(callbackCount.get() + 1) } }
    val visibleStarted = FakePdfSession.holdNextVisible()
    harness.sendPageNavigationSwipe()
    harness.sendPageNavigationRelease()

    assertTrue(visibleStarted.await(5L, TimeUnit.SECONDS))
    harness.awaitPage { it == 1 }
    harness.runOnMain {
      val state = harness.surface.pageNavigationState()
      assertTrue(state.handoffPending)
      assertTrue(state.preparedDirections.contains(SwipeDirection.LEFT))
    }
    assertEquals(1, callbackCount.get())

    FakePdfSession.releaseVisible()
    harness.awaitPageNavigationReady()
    harness.runOnMain {
      assertFalse(harness.surface.pageNavigationState().handoffPending)
      assertTrue(harness.surface.pageNavigationState().preparedDirections.isNotEmpty())
    }
  }

  @Test
  fun targetTileFailureUnlocksInteractionForImmediateSecondSwipe() {
    harness.awaitPreparedPagePreview()
    val callbackCount = AtomicReference(0)
    harness.runOnMain { harness.surface.onPageChange = { callbackCount.set(callbackCount.get() + 1) } }
    FakePdfSession.failNextVisible()
    harness.sendPageNavigationSwipe()
    harness.sendPageNavigationRelease()

    harness.awaitPage { it == 1 }
    harness.awaitPageNavigationReady()
    harness.runOnMain {
      assertEquals(1, harness.surface.currentPageInfo().pageIndex)
      assertFalse(harness.surface.pageNavigationState().handoffPending)
      assertEquals(1, callbackCount.get())
      assertEquals(harness.surface.currentViewportState().focus,
        PagePoint(300.0, 350.0))
    }

    harness.awaitPreparedPagePreview()
    harness.sendPageNavigationSwipe()
    harness.sendPageNavigationRelease()
    harness.awaitPage { it == 2 }
    assertEquals(2, callbackCount.get())
  }

  @Test
  fun clearedDocumentInfoUsesViewNotReadyBeforeFinalizeCapture() {
    var error: PdfSessionException? = null
    harness.runOnMain {
      harness.surface.documentCoordinator.clearPublishedDocument()
      harness.surface.clearDocument()
      error = assertThrows(PdfSessionException::class.java) {
        harness.surface.currentDocumentInfo()
      }
    }

    assertEquals("view_not_ready", requireNotNull(error).code)
  }

  @Test
  fun completedInkAndHistoryRemainLocalToEachPage() {
    val states = ArrayList<InkState>()
    harness.runOnMain {
      // installCandidate models create; opened PDFs start from a clean baseline.
      harness.surface.documentCoordinator.markStructuralClean()
      harness.surface.onStateChange = { states += it }
      harness.surface.setEditMode(true)
      dispatch(downEvent(80.0f, 100.0f, 1_000L))
      dispatch(upEvent(180.0f, 100.0f, 1_020L))
      assertEquals(1, harness.surface.completedPagesSnapshot()[0].strokes.size)

      harness.surface.switchPage(1)
      assertEquals(1, harness.surface.completedPagesSnapshot()[0].strokes.size)
      assertEquals(0, harness.surface.completedPagesSnapshot()[1].strokes.size)
      assertEquals(0L, harness.surface.rendererDiagnostics().retainedSourcePathCount)

      dispatch(downEvent(80.0f, 130.0f, 2_000L))
      dispatch(upEvent(180.0f, 130.0f, 2_020L))
      assertEquals(1, harness.surface.completedPagesSnapshot()[1].strokes.size)
      assertEquals(1L, harness.surface.rendererDiagnostics().retainedSourcePathCount)

      harness.surface.switchPage(0)
      assertEquals(1L, harness.surface.rendererDiagnostics().retainedSourcePathCount)
      harness.surface.undo()
      assertEquals(0, harness.surface.completedPagesSnapshot()[0].strokes.size)
      assertEquals(1, harness.surface.completedPagesSnapshot()[1].strokes.size)
      assertEquals(InkState(false, true, true), states.last())

      harness.surface.switchPage(1)
      harness.surface.clear()
      assertEquals(0, harness.surface.completedPagesSnapshot()[1].strokes.size)
      assertEquals(InkState(true, false, false), states.last())
    }
  }

  @Test
  fun editModeAcceptsHistoricalFingerSamplesAndFinalizesTheStroke() {
    harness.runOnMain {
      val states = ArrayList<InkState>()
      // installCandidate models create; opened PDFs start from a clean baseline.
      harness.surface.documentCoordinator.markStructuralClean()
      harness.surface.onStateChange = { states += it }
      harness.surface.setEditMode(true)

      dispatch(downEvent(150.0f, 150.0f, 1_000L))
      val move = motionEvent(MotionEvent.ACTION_MOVE, 162.0f, 150.0f, 1_015L)
      move.addBatch(1_030L, 175.0f, 150.0f, 1.0f, 1.0f, 0)
      dispatch(move)
      dispatch(upEvent(190.0f, 150.0f, 1_050L))

      val finalOutline = harness.surface.completedPagesSnapshot().first().strokes.single()
      assertTrue(finalOutline.cubicSegmentCount > 0)
      assertEquals(listOf(InkState(true, false, true)), states)

      harness.surface.undo()
      harness.surface.redo()
      harness.surface.clear()
      assertEquals(
        listOf(
          InkState(true, false, true),
          InkState(false, true, false),
          InkState(true, false, true),
          InkState(true, false, false),
        ),
        states,
      )
    }
  }

  @Test
  fun viewModeAndRejectedToolsDoNotStartAStroke() {
    harness.runOnMain {
      dispatch(downEvent(150.0f, 150.0f, 1_000L))
      dispatch(upEvent(190.0f, 150.0f, 1_010L))
      assertEquals(0, harness.predictor.recordedEventCount)
      assertNotInProgress(harness.engine, 190.0, 150.0, 1.020)

      harness.surface.setEditMode(true)
      dispatch(downEvent(-1_000.0f, 150.0f, 2_000L))
      assertNotInProgress(harness.engine, 0.0, 150.0, 2.010)

      dispatch(mouseDownEvent(150.0f, 150.0f, 3_000L))
      assertNotInProgress(harness.engine, 150.0, 150.0, 3.010)
    }
  }

  @Test
  fun androidPredictorReplacesOnlyTheTemporaryPredictionBatch() {
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))

      val predicted = motionEvent(MotionEvent.ACTION_MOVE, 180.0f, 150.0f, 1_030L)
      predicted.addBatch(1_020L, 170.0f, 150.0f, 1.0f, 1.0f, 0)
      harness.predictor.nextPrediction = predicted
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 160.0f, 150.0f, 1_010L))

      val predictionRequest = harness.frontBuffer.requests.last()
      assertTrue(predictionRequest.predictionPathCount > 0)
      assertEquals(0, predictionRequest.realPathCount)
      assertTrue(predictionRequest.paths.none {
        it.role == LowLatencyInkPathRole.REAL
      })
      assertTrue(predictionRequest.paths.any {
        it.role == LowLatencyInkPathRole.PREDICTION
      })

      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 170.0f, 150.0f, 1_020L))
      val clearedPredictionRequest = harness.frontBuffer.requests.last()
      assertEquals(0, clearedPredictionRequest.predictionPathCount)

      dispatch(upEvent(180.0f, 150.0f, 1_030L))
      assertEquals(4, harness.predictor.recordedEventCount)
      assertEquals(1, harness.surface.completedPagesSnapshot().first().strokes.size)
    }
  }

  @Test
  fun invalidMoveClearsVisiblePredictionWithoutMutatingTheNativeStroke() {
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))

      val predicted = motionEvent(MotionEvent.ACTION_MOVE, 210.0f, 150.0f, 1_040L)
      predicted.addBatch(1_030L, 195.0f, 150.0f, 1.0f, 1.0f, 0)
      harness.predictor.nextPrediction = predicted
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 170.0f, 150.0f, 1_020L))

      val predictionRequest = harness.frontBuffer.requests.last()
      assertTrue(predictionRequest.predictionPathCount > 0)
      val predictionBounds = predictionRequest.paths
        .filter { it.role == LowLatencyInkPathRole.PREDICTION }
        .map { it.data.bounds }
        .reduce { first, second -> first.union(second) }
      val expectedPredictionRegion = LowLatencyInkDirtyRegionCalculator.calculate(
        previous = null,
        current = LowLatencyInkBoundsSnapshot(
          liveTail = null,
          prediction = predictionBounds,
          newlyStable = null,
        ),
        transform = predictionRequest.pageToView,
        viewWidth = predictionRequest.bufferWidth,
        viewHeight = predictionRequest.bufferHeight,
      )
      assertTrue(expectedPredictionRegion != null)

      val before = harness.surface.presentationDiagnostics()
      val requestCountBefore = harness.frontBuffer.requests.size
      val invalidMove = motionEvent(MotionEvent.ACTION_MOVE, -1_000.0f, -1_000.0f, 1_050L)
      invalidMove.addBatch(1_045L, -1_000.0f, -1_000.0f, 1.0f, 1.0f, 0)
      dispatch(invalidMove)

      val clearRequest = harness.frontBuffer.requests.last()
      val after = harness.surface.presentationDiagnostics()
      assertEquals(requestCountBefore + 1, harness.frontBuffer.requests.size)
      assertEquals(before.realNativeMutationCount, after.realNativeMutationCount)
      assertEquals(0, clearRequest.predictionPathCount)
      assertTrue(clearRequest.paths.none {
        it.role == LowLatencyInkPathRole.PREDICTION
      })
      assertTrue(clearRequest.dirtyRegion.contains(expectedPredictionRegion!!))
      assertTrue(after.frontBufferOwnsActiveInk)
      assertEquals(before.acceptedRequestCount + 1, after.acceptedRequestCount)
    }
  }

  @Test
  fun rejectedInvalidMoveClearCancelsTheActiveStroke() {
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))

      val predicted = motionEvent(MotionEvent.ACTION_MOVE, 210.0f, 150.0f, 1_040L)
      predicted.addBatch(1_030L, 195.0f, 150.0f, 1.0f, 1.0f, 0)
      harness.predictor.nextPrediction = predicted
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 170.0f, 150.0f, 1_020L))

      val before = harness.surface.presentationDiagnostics()
      harness.frontBuffer.acceptRequests = false
      val invalidMove = motionEvent(MotionEvent.ACTION_MOVE, -1_000.0f, -1_000.0f, 1_050L)
      invalidMove.addBatch(1_045L, -1_000.0f, -1_000.0f, 1.0f, 1.0f, 0)
      dispatch(invalidMove)

      val after = harness.surface.presentationDiagnostics()
      assertEquals(before.realNativeMutationCount, after.realNativeMutationCount)
      assertEquals(before.cancelledCount + 1, after.cancelledCount)
      assertFalse(after.frontBufferOwnsActiveInk)
      assertEquals(0, harness.surface.completedPagesSnapshot().first().strokes.size)
      assertNotInProgress(harness.engine, 170.0, 150.0, 1.060)
    }
  }

  @Test
  fun changedMotionEventWithHistoricalSamplesSubmitsExactlyOneBoundedRequest() {
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))

      val move = motionEvent(MotionEvent.ACTION_MOVE, 160.0f, 150.0f, 1_010L)
      move.addBatch(1_020L, 170.0f, 150.0f, 1.0f, 1.0f, 0)
      move.addBatch(1_030L, 180.0f, 150.0f, 1.0f, 1.0f, 0)
      dispatch(move)

      assertEquals(2, harness.frontBuffer.requests.size)
      val request = harness.frontBuffer.requests.last()
      assertTrue(request.dirtyRegion.right > request.dirtyRegion.left)
      assertTrue(request.paths.isNotEmpty())
      assertTrue(request.paths.sumOf { it.data.commands.size } < 200)
      assertEquals(request.paths.count { it.role == LowLatencyInkPathRole.REAL }, request.realPathCount)
      assertEquals(
        request.paths.count { it.role == LowLatencyInkPathRole.PREDICTION },
        request.predictionPathCount,
      )
      assertTrue(harness.surface.presentationDiagnostics().frontBufferOwnsActiveInk)
      assertEquals(2L, harness.surface.presentationDiagnostics().changedEventCount)
      val diagnostics = harness.surface.presentationDiagnostics()
      assertEquals(3L, diagnostics.rawRealSampleCount)
      assertEquals(1L, diagnostics.realBatchCount)
      assertEquals(1L, diagnostics.realNativeMutationCount)
      assertEquals(1L, diagnostics.realFrameCopyCount)
      assertEquals(1L, diagnostics.realFrameDecodeCount)
    }
  }

  @Test
  fun completedStrokeInstallsOneDurableOutlineBeforeRequestingHandoff() {
    harness.frontBuffer.acceptHandoffs = true
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 180.0f, 150.0f, 1_020L))
      dispatch(upEvent(190.0f, 150.0f, 1_030L))

      assertEquals(1, harness.surface.completedPagesSnapshot().first().strokes.size)
      assertEquals(1, harness.frontBuffer.handoffRequests.size)
      assertEquals(2L, harness.surface.presentationDiagnostics().acceptedRequestCount)
      assertFalse(harness.surface.presentationDiagnostics().frontBufferOwnsActiveInk)
    }
  }

  @Test
  fun delayedSameGenerationAcknowledgementAfterSuccessfulUpDoesNotMutateClearedComposition() {
    harness.frontBuffer.acknowledgeImmediately = false
    harness.frontBuffer.acceptHandoffs = true
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))
      for (index in 1..24) {
        dispatch(
          motionEvent(
            MotionEvent.ACTION_MOVE,
            150.0f + index * 5.0f,
            (150.0 + kotlin.math.sin(index * 0.45) * 18.0).toFloat(),
            1_000L + index * 100L,
          ),
        )
      }
      dispatch(upEvent(280.0f, 150.0f, 3_500L))

      val beforeDelayedAcknowledgement = harness.surface.presentationDiagnostics()
      assertEquals(1, harness.surface.completedPagesSnapshot().first().strokes.size)
      assertEquals(
        "eligible in-viewport gesture must request handoff; diagnostics=${harness.surface.presentationDiagnostics()}",
        1,
        harness.frontBuffer.handoffRequests.size,
      )
      assertFalse(beforeDelayedAcknowledgement.frontBufferOwnsActiveInk)
      assertEquals(0, beforeDelayedAcknowledgement.retainedCommittedContourCount)
      assertEquals(0, beforeDelayedAcknowledgement.retainedPredictionContourCount)
      assertEquals(0L, beforeDelayedAcknowledgement.stableBoundarySubmitted)
      assertEquals(0L, beforeDelayedAcknowledgement.stableBoundaryAcknowledged)

      val delayedIndex = harness.frontBuffer.queuedAcknowledgements.indexOfFirst { true }
      assertTrue(
        "expected an acknowledgement for an accepted eligible gesture; " +
          "requests=${harness.frontBuffer.requests.size}, handoffs=${harness.frontBuffer.handoffRequests.size}",
        delayedIndex >= 0,
      )
      val delayedAcknowledgement = harness.frontBuffer.queuedAcknowledgements[delayedIndex]
      assertEquals(
        harness.frontBuffer.handoffRequests.single().first,
        delayedAcknowledgement.generation,
      )
      harness.frontBuffer.deliverQueuedAcknowledgement(delayedIndex)

      val afterDelayedAcknowledgement = harness.surface.presentationDiagnostics()
      assertFalse(afterDelayedAcknowledgement.frontBufferOwnsActiveInk)
      assertEquals(0, afterDelayedAcknowledgement.retainedCommittedContourCount)
      assertEquals(0, afterDelayedAcknowledgement.retainedPredictionContourCount)
      assertEquals(0L, afterDelayedAcknowledgement.stableBoundarySubmitted)
      assertEquals(0L, afterDelayedAcknowledgement.stableBoundaryAcknowledged)
      assertEquals(1, harness.surface.completedPagesSnapshot().first().strokes.size)
      assertEquals(1, harness.frontBuffer.handoffRequests.size)
      assertNotInProgress(harness.engine, 280.0, 150.0, 3.500)
    }
  }

  @Test
  fun cancelledStrokeDoesNotAppendHistoryOrLeaveActivePresentation() {
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 180.0f, 150.0f, 1_020L))
      dispatch(motionEvent(MotionEvent.ACTION_CANCEL, 180.0f, 150.0f, 1_030L))

      assertEquals(0, harness.surface.completedPagesSnapshot().first().strokes.size)
      assertFalse(harness.surface.presentationDiagnostics().frontBufferOwnsActiveInk)
    }
  }

  @Test
  fun cancelledPointerFlagUsesTheSameCleanupAsActionCancel() {
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))
      dispatch(motionEvent(MotionEvent.ACTION_UP, 180.0f, 150.0f, 1_020L, flags = MotionEvent.FLAG_CANCELED))

      assertEquals(0, harness.surface.completedPagesSnapshot().first().strokes.size)
      assertFalse(harness.surface.presentationDiagnostics().frontBufferOwnsActiveInk)
    }
  }

  @Test
  fun predictionReplacementDirtyRegionIncludesTheOldPrediction() {
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))

      val predicted = motionEvent(MotionEvent.ACTION_MOVE, 210.0f, 150.0f, 1_040L)
      predicted.addBatch(1_030L, 195.0f, 150.0f, 1.0f, 1.0f, 0)
      harness.predictor.nextPrediction = predicted
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 170.0f, 150.0f, 1_020L))
      val predictionRequest = harness.frontBuffer.requests.last()

      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 180.0f, 150.0f, 1_030L))
      val replacementRequest = harness.frontBuffer.requests.last()

      assertTrue(replacementRequest.dirtyRegion.right >= predictionRequest.dirtyRegion.right)
      assertTrue(replacementRequest.dirtyRegion.left <= predictionRequest.dirtyRegion.right)
      assertEquals(3, harness.frontBuffer.requests.size)
    }
  }

  @Test
  fun unavailablePresenterRejectsDownBeforeNativeMutation() {
    harness.frontBuffer.acceptRequests = false
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))

      val diagnostics = harness.surface.presentationDiagnostics()
      assertEquals(0L, diagnostics.acceptedRequestCount)
      assertFalse(diagnostics.frontBufferOwnsActiveInk)
      assertEquals(0, harness.frontBuffer.requests.size)
      assertNotInProgress(harness.engine, 180.0, 150.0, 1.020)
    }
  }

  @Test
  fun presenterLossCancelsTheActiveStrokeWithoutHistoryLeakage() {
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))
      harness.frontBuffer.acceptRequests = false
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 180.0f, 150.0f, 1_020L))

      assertEquals(0, harness.surface.completedPagesSnapshot().first().strokes.size)
      assertFalse(harness.surface.presentationDiagnostics().frontBufferOwnsActiveInk)
      assertNotInProgress(harness.engine, 180.0, 150.0, 1.030)
    }
  }

  @Test
  fun rendererLifecycleLossCancelsNativeAndReleasesRollingGeometry() {
    harness.runOnMain {
      harness.surface.setEditMode(true)
      dispatch(downEvent(150.0f, 150.0f, 1_000L))
      dispatch(motionEvent(MotionEvent.ACTION_MOVE, 180.0f, 150.0f, 1_020L))
      assertTrue(harness.surface.presentationDiagnostics().retainedCommittedContourCount > 0)

      harness.frontBuffer.signalLifecycleLoss()

      val diagnostics = harness.surface.presentationDiagnostics()
      assertFalse(diagnostics.frontBufferOwnsActiveInk)
      assertEquals(0, diagnostics.retainedCommittedContourCount)
      assertEquals(0, diagnostics.retainedPredictionContourCount)
      assertEquals(0L, diagnostics.stableBoundarySubmitted)
      assertEquals(0L, diagnostics.stableBoundaryAcknowledged)
      assertEquals(2, diagnostics.lastCancellationReason)
      assertEquals(0, harness.surface.completedPagesSnapshot().first().strokes.size)
      assertNotInProgress(harness.engine, 180.0, 150.0, 1.030)
    }
  }

  private fun dispatch(event: MotionEvent) {
    try {
      assertTrue(harness.surface.onTouchEvent(event))
    } finally {
      event.recycle()
    }
  }

  private fun assertNotInProgress(
    engine: InkEngine,
    x: Double,
    y: Double,
    time: Double,
  ) {
    val error = assertThrows(InkStrokeMutationException::class.java) {
      engine.updateAndRead(x, y, time)
    }
    assertEquals(InkEngine.STATUS_NOT_IN_PROGRESS, error.status)
  }

  private fun downEvent(x: Float, y: Float, eventTime: Long): MotionEvent {
    return motionEvent(MotionEvent.ACTION_DOWN, x, y, eventTime, MotionEvent.TOOL_TYPE_FINGER)
  }

  private fun upEvent(x: Float, y: Float, eventTime: Long): MotionEvent {
    return motionEvent(MotionEvent.ACTION_UP, x, y, eventTime, MotionEvent.TOOL_TYPE_FINGER)
  }

  private fun mouseDownEvent(x: Float, y: Float, eventTime: Long): MotionEvent {
    return motionEvent(
      MotionEvent.ACTION_DOWN,
      x,
      y,
      eventTime,
      MotionEvent.TOOL_TYPE_MOUSE,
      InputDevice.SOURCE_MOUSE,
    )
  }

  private fun motionEvent(
    action: Int,
    x: Float,
    y: Float,
    eventTime: Long,
    toolType: Int = MotionEvent.TOOL_TYPE_FINGER,
    source: Int = InputDevice.SOURCE_TOUCHSCREEN,
    flags: Int = 0,
  ): MotionEvent {
    val properties = MotionEvent.PointerProperties().apply {
      id = 0
      this.toolType = toolType
    }
    val coordinates = MotionEvent.PointerCoords().apply {
      this.x = x
      this.y = y
      pressure = 1.0f
      size = 1.0f
      setAxisValue(MotionEvent.AXIS_TILT, 0.0f)
      setAxisValue(MotionEvent.AXIS_ORIENTATION, 0.0f)
    }
    return MotionEvent.obtain(
      1_000L,
      eventTime,
      action,
      1,
      arrayOf(properties),
      arrayOf(coordinates),
      0,
      0,
      1.0f,
      1.0f,
      0,
      0,
      source,
      flags,
    )
  }

  private inner class SurfaceHarness(
    private val previewScheduler: PageNavigationPreviewScheduler? = null,
    private val settlementDriver: PageNavigationSettlementDriver? = null,
  ) {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val worker = PdfSessionWorker(opener = FakePdfSession)
    private val generation = worker.reserveOpenAttemptId(0L)
    val engine = InkEngine()
    val predictor = RecordingPredictor()
    val frontBuffer = RecordingFrontBufferHost()
    val coordinator = MutableDocumentCoordinator(
      generation = generation,
      sessionWorker = worker,
      artifactPolicy = CacheArtifactPolicy.initialize(instrumentation.targetContext),
    )
    val surface: SurfaceView

    init {
      val createdSurface = AtomicReference<SurfaceView>()
      instrumentation.runOnMainSync {
        createdSurface.set(
          SurfaceView(
            instrumentation.targetContext,
            engine,
            predictor = predictor,
            lowLatencyInk = frontBuffer,
            pageNavigationPreviewScheduler = previewScheduler,
            pageNavigationSettlementDriver = settlementDriver,
            documentCoordinator = coordinator,
          ),
        )
      }
      surface = createdSurface.get()

      val result = AtomicReference<Result<PdfSessionInfo>>()
      val completed = CountDownLatch(1)
      worker.prepareOpen(generation, "test.pdf", null) { prepared ->
        result.set(prepared)
        assertTrue(worker.commitPreparedOpen(generation) { committed ->
          if (committed.isFailure) result.set(Result.failure(checkNotNull(committed.exceptionOrNull())))
          completed.countDown()
        })
      }
      assertTrue(completed.await(5L, TimeUnit.SECONDS))
      val info = result.get().getOrThrow()
      runOnMain {
        surface.layout(0, 0, 300, 300)
        setDocument(info)
      }
    }

    fun runOnMain(action: () -> Unit) {
      instrumentation.runOnMainSync(action)
    }

    fun documentInfo(): PdfSessionInfo = FakePdfSession.open("test.pdf", 1L).info

    fun setDocument(
      info: PdfSessionInfo,
      zoom: Double? = null,
      focus: PagePoint? = null,
      fitToPage: Boolean = true,
    ) {
      val pages = info.pages.map(::InkPageState)
      surface.documentCoordinator.installCandidate(info.sourcePath, pages, pages.first().id)
      surface.installDocumentPresentation(zoom, focus, fitToPage)
    }

    fun awaitPreparedPagePreview() {
      val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5L)
      var lastState: PageNavigationController.PageNavigationDiagnostics? = null
      while (System.nanoTime() < deadline) {
        var prepared = false
        runOnMain {
          lastState = surface.pageNavigationState()
          prepared = lastState?.preparedDirections?.isNotEmpty() == true
        }
        if (prepared) return
        Thread.sleep(20L)
      }
      assertTrue("state=$lastState", lastState?.preparedDirections?.isNotEmpty() == true)
    }

    /** Enqueues a no-op worker fence so all earlier submissions have settled. */
    fun awaitWorkerIdle() {
      val completed = CountDownLatch(1)
      worker.renderTiles(1L, Long.MIN_VALUE, emptyList()) { completed.countDown() }
      assertTrue(
        "PDF worker did not drain within the test timeout",
        completed.await(5L, TimeUnit.SECONDS),
      )
    }

    fun sendPageNavigationSwipe() {
      runOnMain {
        dispatch(downEvent(150.0f, 150.0f, 10_000L))
        dispatch(motionEvent(MotionEvent.ACTION_MOVE, 0.0f, 150.0f, 10_020L))
      }
    }

    fun sendPageNavigationRelease() {
      runOnMain { dispatch(upEvent(0.0f, 150.0f, 10_040L)) }
    }

    fun awaitPage(predicate: (Int) -> Boolean) {
      val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5L)
      while (System.nanoTime() < deadline) {
        var page = -1
        runOnMain { page = surface.currentPageInfo().pageIndex }
        if (predicate(page)) return
        Thread.sleep(20L)
      }
      var page = -1
      runOnMain { page = surface.currentPageInfo().pageIndex }
      assertTrue(predicate(page))
    }

    fun awaitPageNavigationReady() {
      val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5L)
      while (System.nanoTime() < deadline) {
        var pending = true
        runOnMain { pending = surface.pageNavigationState().handoffPending }
        if (!pending) return
        Thread.sleep(20L)
      }
      runOnMain { assertFalse(surface.pageNavigationState().handoffPending) }
    }

    fun close() {
      runOnMain { surface.clearDocument() }
      engine.close()
      worker.close()
    }
  }

  private class RecordingFrontBufferHost : LowLatencyInkHost {
    val requests = ArrayList<LowLatencyInkDrawRequest>()
    val handoffRequests = ArrayList<Pair<Long, Long>>()
    val queuedAcknowledgements = ArrayList<LowLatencyInkPresentationAcknowledgement>()
    var acceptRequests = true
    var acceptHandoffs = false
    var acknowledgeImmediately = true
    private var acknowledgementListener:
      (LowLatencyInkPresentationAcknowledgement) -> Unit = {}
    private var lifecycleCancellationListener: () -> Unit = {}

    override val isAvailable: Boolean
      get() = acceptRequests

    override fun requestDraw(update: LowLatencyInkDrawRequest): Boolean {
      requests += update
      if (acceptRequests) {
        val acknowledgement = LowLatencyInkPresentationAcknowledgement(
          generation = update.generation,
          sequence = update.sequence,
          stableBoundary = update.stableBoundary,
        )
        if (acknowledgeImmediately) acknowledgementListener(acknowledgement)
        else queuedAcknowledgements += acknowledgement
      }
      return acceptRequests
    }

    override fun setPresentationAcknowledgementListener(
      listener: (LowLatencyInkPresentationAcknowledgement) -> Unit,
    ) {
      acknowledgementListener = listener
    }

    override fun setLifecycleCancellationListener(listener: () -> Unit) {
      lifecycleCancellationListener = listener
    }

    fun signalLifecycleLoss() = lifecycleCancellationListener()

    fun deliverQueuedAcknowledgement(index: Int) {
      acknowledgementListener(queuedAcknowledgements.removeAt(index))
    }

    override fun handoff(
      generation: Long,
      sequence: Long,
      finalSnapshot: LowLatencyInkFinalSnapshot,
    ): Boolean {
      handoffRequests += generation to sequence
      return acceptHandoffs
    }

    override fun resetActive(generation: Long) {
      requests.clear()
      queuedAcknowledgements.clear()
    }

  }

  private class RecordingPredictor : InputPredictor {
    var recordedEventCount = 0
      private set
    var nextPrediction: MotionEvent? = null

    override fun record(event: MotionEvent) {
      recordedEventCount += 1
    }

    override fun predict(): MotionEvent? {
      val result = nextPrediction
      nextPrediction = null
      return result
    }
  }

  private class ManualSettlementDriver : PageNavigationSettlementDriver {
    private data class Pending(
      val onProgress: (Float) -> Unit,
      val onEnd: () -> Unit,
      var cancelled: Boolean = false,
    ) : PageNavigationSettlementDriver.Handle {
      override fun cancel() {
        cancelled = true
      }
    }

    private val pending = ArrayList<Pending>()

    override fun start(
      from: Float,
      to: Float,
      durationMillis: Long,
      onProgress: (Float) -> Unit,
      onEnd: () -> Unit,
    ): PageNavigationSettlementDriver.Handle {
      return Pending(onProgress, onEnd).also(pending::add)
    }

    fun pendingCount(): Int = pending.size

    fun finish(index: Int) {
      pending[index].onEnd()
    }
  }

  private class ManualPreviewScheduler : PageNavigationPreviewScheduler {
    private data class Pending(
      val request: PdfTileRequest,
      val completion: (Result<PdfTile>) -> Unit,
    )

    private val pending = ArrayList<Pending>()
    private val requestStarted = CountDownLatch(1)

    override fun updateEpoch(generation: Long, previewEpoch: Long) = Unit

    override fun renderPreview(
      generation: Long,
      previewEpoch: Long,
      request: PdfTileRequest,
      completion: (Result<PdfTile>) -> Unit,
    ) {
      synchronized(pending) { pending += Pending(request, completion) }
      requestStarted.countDown()
    }

    fun awaitRequest(): Boolean = requestStarted.await(5L, TimeUnit.SECONDS)

    fun completeLatest() {
      val next = synchronized(pending) { checkNotNull(pending.lastOrNull()) }
      next.completion(
        Result.success(
          PdfTile(
            next.request,
            Bitmap.createBitmap(next.request.widthPx, next.request.heightPx, Bitmap.Config.ARGB_8888),
          ),
        ),
      )
    }
  }

  private object FakePdfSession : PdfSessionOpener {
    @Volatile var previewRenderCount = 0
      private set
    @Volatile private var delayPreviews = false
    @Volatile private var delayNextVisible = false
    @Volatile private var failNextVisibleRequest = false
    @Volatile private var previewRelease = CountDownLatch(0)
    @Volatile private var previewStarted = CountDownLatch(0)
    @Volatile private var visibleRelease = CountDownLatch(0)
    @Volatile private var visibleStarted = CountDownLatch(0)

    fun holdPreviews() {
      previewStarted = CountDownLatch(1)
      previewRelease = CountDownLatch(1)
      delayPreviews = true
    }

    fun releasePreviews() {
      delayPreviews = false
      previewRelease.countDown()
    }

    fun awaitPreviewStarted(): Boolean = previewStarted.await(5L, TimeUnit.SECONDS)

    fun holdNextVisible(): CountDownLatch {
      visibleStarted = CountDownLatch(1)
      visibleRelease = CountDownLatch(1)
      delayNextVisible = true
      return visibleStarted
    }

    fun releaseVisible() {
      delayNextVisible = false
      visibleRelease.countDown()
    }

    fun failNextVisible() {
      failNextVisibleRequest = true
    }

    fun resetControls() {
      previewRenderCount = 0
      delayPreviews = false
      delayNextVisible = false
      failNextVisibleRequest = false
      previewRelease.countDown()
      visibleRelease.countDown()
    }

    override fun open(path: String, generation: Long): PdfSessionResource {
      return object : PdfSessionResource {
        override val info = PdfSessionInfo(
          sourcePath = path,
          pages = listOf(
            PdfPageDimensions(300.0, 300.0),
            PdfPageDimensions(600.0, 700.0),
            PdfPageDimensions(800.0, 900.0),
          ),
          generation = generation,
        )

        override fun renderTiles(
          requests: List<PdfTileRequest>,
          beforeEach: () -> Unit,
        ): List<PdfTile> {
          if (requests.any { it.priority == androidPdfTileVisiblePriority }) {
            if (delayNextVisible) {
              delayNextVisible = false
              visibleStarted.countDown()
              check(visibleRelease.await(5L, TimeUnit.SECONDS))
            }
            if (failNextVisibleRequest) {
              failNextVisibleRequest = false
              throw IllegalStateException("controlled target tile failure")
            }
          }
          return requests.map { request ->
            beforeEach()
            PdfTile(
              request,
              Bitmap.createBitmap(request.widthPx, request.heightPx, Bitmap.Config.ARGB_8888),
            )
          }
        }

        override fun renderPreview(
          request: PdfTileRequest,
          beforeRender: () -> Unit,
        ): PdfTile {
          if (delayPreviews) {
            previewStarted.countDown()
            check(previewRelease.await(5L, TimeUnit.SECONDS))
          }
          beforeRender()
          previewRenderCount += 1
          return PdfTile(
            request,
            Bitmap.createBitmap(request.widthPx, request.heightPx, Bitmap.Config.ARGB_8888),
          )
        }

        override fun close() = Unit
      }
    }
  }
}
