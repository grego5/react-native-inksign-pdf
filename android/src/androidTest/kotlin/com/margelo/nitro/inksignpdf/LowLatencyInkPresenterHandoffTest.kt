package com.margelo.nitro.inksignpdf

import android.graphics.Color
import android.widget.FrameLayout
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.ArrayDeque
import java.util.ArrayList
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class LowLatencyInkPresenterHandoffTest : LowLatencyInkPresenterTestBase() {
  @Test
  fun presenterSubmitsFinalSnapshotBeforeOneCommitAndRejectsDuplicateHandoff() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created)
    val token = LowLatencyInkRenderToken(9L, 4L)
    val snapshot = LowLatencyInkFinalSnapshot(
      generation = token.generation,
      sequence = token.sequence,
      paths = listOf(InkPathData(
        commands = listOf(
          InkPathCommand(InkPathCommand.MOVE, 1f, 1f),
          InkPathCommand(InkPathCommand.LINE, 2f, 1f),
          InkPathCommand(InkPathCommand.LINE, 1f, 2f),
          InkPathCommand(InkPathCommand.CLOSE),
        ),
        bounds = InkBounds(1f, 1f, 2f, 2f),
      )),
      pageToView = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
      color = Color.BLACK,
      bufferWidth = 300,
      bufferHeight = 300,
    )

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      presenter.resetActive(token.generation)
      assertTrue(presenter.requestDraw(drawRequest(1L, generation = token.generation)))
      assertTrue(presenter.requestDraw(drawRequest(2L, generation = token.generation)))
      assertTrue(presenter.requestDraw(drawRequest(token.sequence, generation = token.generation)))
      created.single().deferCommitCallback = true
      assertTrue(presenter.handoff(token.generation, token.sequence, snapshot))
      assertFalse(presenter.handoff(token.generation, token.sequence, snapshot))
      created.single().completeDeferredCommit()
      assertEquals(
        listOf(listOf(
          LowLatencyInkRenderToken(9L, 1L),
          LowLatencyInkRenderToken(9L, 2L),
          token,
        )),
        created.single().commitCallbackTokens,
      )
      assertEquals(1, created.single().commitCount)
      assertEquals(
        listOf("front", "front", "front", "commit"),
        created.single().operations.takeLast(4),
      )
      assertEquals(1L, presenter.drawDiagnostics()?.finalMultiBufferSnapshotDrawCount)
      presenter.release()
    }
  }

  @Test
  fun multiBufferCompletionFifoKeepsDelayedCommitTokensCorrelated() {
    val tokenA = LowLatencyInkRenderToken(10L, 1L)
    val tokenB = LowLatencyInkRenderToken(11L, 2L)
    fun snapshot(token: LowLatencyInkRenderToken) = LowLatencyInkFinalSnapshot(
      generation = token.generation,
      sequence = token.sequence,
      paths = listOf(InkPathData(
        listOf(
          InkPathCommand(InkPathCommand.MOVE, 1f, 1f),
          InkPathCommand(InkPathCommand.LINE, 2f, 1f),
          InkPathCommand(InkPathCommand.LINE, 1f, 2f),
          InkPathCommand(InkPathCommand.CLOSE),
        ),
        InkBounds(1f, 1f, 2f, 2f),
      )),
      PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
      Color.BLACK,
      20,
      20,
    )
    val snapshots = mapOf(tokenA to snapshot(tokenA), tokenB to snapshot(tokenB))
    val prepared = ArrayList<Pair<Long, Long>>()
    val callback = LowLatencyInkDrawCallback(
      AtomicLong(tokenB.generation),
      AtomicLong(0L),
      LowLatencyInkPayloadMailbox(),
      finalSnapshotFor = { snapshots[it] },
      onMultiBufferedLayerPrepared = { generation, sequence, drawn ->
        if (drawn) prepared += generation to sequence
      },
    )
    val canvas = android.graphics.Canvas(
      android.graphics.Bitmap.createBitmap(20, 20, android.graphics.Bitmap.Config.ARGB_8888),
    )

    callback.installFinalSnapshot(tokenA)
    callback.onDrawMultiBufferedLayer(canvas, 20, 20, listOf(tokenA, tokenB))
    callback.installFinalSnapshot(tokenB)
    callback.onDrawMultiBufferedLayer(canvas, 20, 20, listOf(tokenA, tokenB))
    callback.completeMultiBufferedLayerForTest()
    callback.completeMultiBufferedLayerForTest()

    assertEquals(
      listOf(tokenA.generation to tokenA.sequence, tokenB.generation to tokenB.sequence),
      prepared,
    )
    callback.enqueueFinalClear(tokenB.generation)
    callback.completeMultiBufferedLayerForTest()
    assertEquals(2, prepared.size)
  }

  @Test
  fun staleClearCompletionCannotDiscardANewerFinalSnapshot() {
    val oldToken = LowLatencyInkRenderToken(20L, 1L)
    val newToken = LowLatencyInkRenderToken(21L, 1L)
    val newSnapshot = LowLatencyInkFinalSnapshot(
      generation = newToken.generation,
      sequence = newToken.sequence,
      paths = listOf(InkPathData(
        listOf(
          InkPathCommand(InkPathCommand.MOVE, 1f, 1f),
          InkPathCommand(InkPathCommand.LINE, 4f, 1f),
          InkPathCommand(InkPathCommand.LINE, 1f, 4f),
          InkPathCommand(InkPathCommand.CLOSE),
        ),
        InkBounds(1f, 1f, 4f, 4f),
      )),
      pageToView = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
      color = Color.BLACK,
      bufferWidth = 20,
      bufferHeight = 20,
    )
    val prepared = ArrayList<Pair<Long, Long>>()
    val callback = LowLatencyInkDrawCallback(
      AtomicLong(newToken.generation),
      AtomicLong(0L),
      LowLatencyInkPayloadMailbox(),
      finalSnapshotFor = { token -> newSnapshot.takeIf { token == newToken } },
      onMultiBufferedLayerPrepared = { generation, sequence, drawn ->
        if (drawn) prepared += generation to sequence
      },
    )
    val canvas = android.graphics.Canvas(
      android.graphics.Bitmap.createBitmap(20, 20, android.graphics.Bitmap.Config.ARGB_8888),
    )

    callback.enqueueFinalClear(oldToken.generation)
    callback.installFinalSnapshot(newToken)
    callback.completeMultiBufferedLayerForTest()
    callback.onDrawMultiBufferedLayer(canvas, 20, 20, listOf(newToken))
    callback.completeMultiBufferedLayerForTest()

    assertEquals(listOf(newToken.generation to newToken.sequence), prepared)
    assertEquals(1L, callback.diagnostics().finalMultiBufferSnapshotDrawCount)
    assertEquals(1L, callback.diagnostics().staleCallbackCount)
  }

  @Test
  fun staleFailedPreparationCannotCancelNewerPendingHandoff() {
    val mainView = FrameLayout(instrumentation.targetContext)
    val surfaceView = android.view.SurfaceView(instrumentation.targetContext)
    var clearCount = 0
    val handoff = LowLatencyInkHandoff(
      mainView = mainView,
      surfaceView = surfaceView,
      clearFrontBuffer = { clearCount += 1; true },
      registerFrameCommit = {},
    )

    instrumentation.runOnMainSync {
      handoff.onFrontBufferDrawAccepted(1L, 1L)
      assertTrue(handoff.requestHandoff(1L, 1L))
      assertTrue(handoff.cancel())
      handoff.onFrontBufferDrawAccepted(2L, 1L)
      assertTrue(handoff.requestHandoff(2L, 1L))
      assertFalse(handoff.onMultiBufferedLayerFailed(1L, 1L))
      assertEquals(
        LowLatencyInkHandoffPhase.FINAL_SNAPSHOT_PENDING,
        handoff.diagnostics().phase,
      )
      assertEquals(1, clearCount)
    }
  }

  @Test
  fun v29HandoffClearsOnlyAfterHwuiFrameCommitAndAnimationContinuation() {
    val mainView = FrameLayout(instrumentation.targetContext)
    val surfaceView = android.view.SurfaceView(instrumentation.targetContext)
    val posted = ArrayDeque<Runnable>()
    var clearCount = 0
    val handoff = LowLatencyInkHandoff(
      mainView = mainView,
      surfaceView = surfaceView,
      clearFrontBuffer = {
        clearCount += 1
        true
      },
      postOnAnimation = { posted += it },
      removeCallbacks = { posted.remove(it) },
      registerFrameCommit = { posted += it },
    )

    instrumentation.runOnMainSync {
      handoff.onFrontBufferDrawAccepted(7L, 3L)
      assertTrue(handoff.requestHandoff(7L, 3L))
      assertEquals(
        LowLatencyInkHandoffPhase.FINAL_SNAPSHOT_PENDING,
        handoff.diagnostics().phase,
      )
      assertFalse(handoff.requestHandoff(7L, 3L))
      handoff.onMultiBufferedLayerPrepared(7L, 3L)
      assertEquals(1, posted.size)
      posted.removeFirst().run()
      assertEquals(0, clearCount)
      assertEquals(1, posted.size)
      posted.removeFirst().run()
      assertEquals(1, clearCount)
      assertEquals(0F, surfaceView.translationX, 0F)
      assertEquals(LowLatencyInkHandoffPhase.RESTORED, handoff.diagnostics().phase)
      assertEquals(1L, handoff.diagnostics().completedHwuiFrameCount)
      assertEquals(1L, handoff.diagnostics().overlayClearedCount)
      assertEquals(1L, handoff.diagnostics().overlayRestoredCount)
    }
  }

  @Test
  fun cancelledHandoffDropsLateCallbackAndRestoresWithoutRetainingPixels() {
    val mainView = FrameLayout(instrumentation.targetContext)
    val surfaceView = android.view.SurfaceView(instrumentation.targetContext)
    val posted = ArrayList<Runnable>()
    var clearCount = 0
    val handoff = LowLatencyInkHandoff(
      mainView = mainView,
      surfaceView = surfaceView,
      clearFrontBuffer = {
        clearCount += 1
        true
      },
      postOnAnimation = { posted += it },
      removeCallbacks = { },
      registerFrameCommit = { posted += it },
    )

    instrumentation.runOnMainSync {
      handoff.onFrontBufferDrawAccepted(11L, 8L)
      assertTrue(handoff.requestHandoff(11L, 8L))
      handoff.onMultiBufferedLayerPrepared(11L, 8L)
      val lateCallback = posted.single()
      assertTrue(handoff.cancel())
      assertEquals(1, clearCount)
      assertEquals(0F, surfaceView.translationX, 0F)
      lateCallback.run()
      assertEquals(1, clearCount)
      assertEquals(1L, handoff.diagnostics().staleCallbackCount)
      assertEquals(LowLatencyInkHandoffPhase.IDLE, handoff.diagnostics().phase)
    }
  }
}
