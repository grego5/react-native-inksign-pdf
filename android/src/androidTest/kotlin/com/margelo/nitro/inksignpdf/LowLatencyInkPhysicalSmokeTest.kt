package com.margelo.nitro.inksignpdf

import android.graphics.Color
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LowLatencyInkPhysicalSmokeTest {
  @Test
  fun api33PlusRendererAcceptsPreservedDrawsAndReset() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val scenario = ActivityScenario.launch(LowLatencyInkSmokeActivity::class.java)
    val activityRef = AtomicReference<LowLatencyInkSmokeActivity>()
    scenario.onActivity { activityRef.set(it) }
    val activity = activityRef.get()
    val presenter = activity.presenter

    try {
      val surfaceReady = activity.surfaceCreated.await(5L, TimeUnit.SECONDS)
      assertTrue(
        "Surface was not created: focus=${activity.hasWindowFocus}, " +
          "screenWake=${activity.screenWakeConfigured}, " +
          "keyguard=${activity.keyguardDismissalSucceeded}, " +
          "keyguardCallback=${activity.keyguardDismissalCompleted.count == 0L}",
        surfaceReady,
      )
      instrumentation.runOnMainSync {
        val rendererDiagnostics = presenter.diagnostics()
        assertEquals(1, rendererDiagnostics.presenterState)
        assertTrue(rendererDiagnostics.overlayAttached)
        assertTrue(rendererDiagnostics.viewAttached)
        assertTrue(rendererDiagnostics.surfaceAvailable)
        assertTrue(rendererDiagnostics.surfaceValid)
        assertTrue(rendererDiagnostics.overlayAttachCount > 0)
        assertTrue(rendererDiagnostics.surfaceCreateCount > 0)
        assertEquals(1, rendererDiagnostics.rendererCreateSuccesses)
        assertTrue(rendererDiagnostics.rendererPresent)
        assertTrue(rendererDiagnostics.rendererValid)
        val bufferWidth = presenter.view.width
        val bufferHeight = presenter.view.height
        assertTrue(bufferWidth > 0)
        assertTrue(bufferHeight > 0)
        presenter.resetActive(1L)
        val firstRequest = drawRequest(1L, 1L, 10, 10, 80, 80, bufferWidth, bufferHeight)
        assertTrue(presenter.requestDraw(firstRequest))
        val secondRegion = InkDirtyRegion(10, 10, 180, 180)
        val secondRequest = drawRequest(
          1L, 2L, 120, 120, 180, 180, bufferWidth, bufferHeight,
        ).let { request ->
          request.copy(
            dirtyRegion = secondRegion,
            paths = firstRequest.paths + request.paths,
            realPathCount = 2,
            predictionPathCount = 2,
          )
        }
        assertTrue(
          presenter.requestDraw(secondRequest),
        )
      }
      val callbackDeadline = SystemClock.elapsedRealtime() + 5_000L
      var callbackDiagnostics: LowLatencyInkDrawDiagnostics
      while (true) {
        val current = AtomicReference<LowLatencyInkDrawDiagnostics>()
        instrumentation.runOnMainSync { current.set(requireNotNull(presenter.drawDiagnostics())) }
        callbackDiagnostics = current.get()
        if (callbackDiagnostics.callbackCount >= 2L ||
          SystemClock.elapsedRealtime() >= callbackDeadline
        ) break
        SystemClock.sleep(25L)
      }
      assertTrue(callbackDiagnostics.callbackCount >= 2L)
      assertTrue(callbackDiagnostics.drawingCallbackCount >= 1L)
      assertTrue(callbackDiagnostics.renderedRegionCount >= 1L)
      assertTrue(callbackDiagnostics.cyanRealPathCount > 0L)
      instrumentation.runOnMainSync {
        val diagnostics = presenter.diagnostics()
        assertEquals(2, diagnostics.acceptedSubmissionCount)
        assertEquals(0, diagnostics.rejectedSubmissionCount)
        assertEquals(0, diagnostics.rendererMissingRejections)
        assertEquals(0, diagnostics.rendererInvalidRejections)
        presenter.clear()
        assertEquals(1, presenter.diagnostics().resetCount)
      }
      instrumentation.waitForIdleSync()
    } finally {
      scenario.close()
    }
  }

  private fun drawRequest(
    generation: Long,
    sequence: Long,
    left: Int,
    top: Int,
    right: Int,
    bottom: Int,
    bufferWidth: Int,
    bufferHeight: Int,
  ) = LowLatencyInkDrawRequest(
    generation = generation,
    sequence = sequence,
    dirtyRegion = InkDirtyRegion(left, top, right, bottom),
    pageToView = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
    bufferWidth = bufferWidth,
    bufferHeight = bufferHeight,
    paths = listOf(
      LowLatencyInkDrawPath(
        key = "smoke-$sequence",
        data = InkPathData(
          commands = listOf(
            InkPathCommand(InkPathCommand.MOVE, left.toFloat(), top.toFloat()),
            InkPathCommand(InkPathCommand.LINE, right.toFloat(), top.toFloat()),
            InkPathCommand(InkPathCommand.LINE, right.toFloat(), bottom.toFloat()),
            InkPathCommand(InkPathCommand.LINE, left.toFloat(), bottom.toFloat()),
            InkPathCommand(InkPathCommand.CLOSE),
          ),
          bounds = InkBounds(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat()),
        ),
        role = LowLatencyInkPathRole.REAL,
        color = Color.CYAN,
      ),
      LowLatencyInkDrawPath(
        key = "smoke-prediction-$sequence",
        data = InkPathData(
          commands = listOf(
            InkPathCommand(InkPathCommand.MOVE, left.toFloat(), top.toFloat()),
            InkPathCommand(InkPathCommand.LINE, right.toFloat(), top.toFloat()),
            InkPathCommand(InkPathCommand.LINE, right.toFloat(), bottom.toFloat()),
            InkPathCommand(InkPathCommand.LINE, left.toFloat(), bottom.toFloat()),
            InkPathCommand(InkPathCommand.CLOSE),
          ),
          bounds = InkBounds(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat()),
        ),
        role = LowLatencyInkPathRole.PREDICTION,
        color = Color.MAGENTA,
      ),
    ),
    realPathCount = 1,
    predictionPathCount = 1,
  )
}
