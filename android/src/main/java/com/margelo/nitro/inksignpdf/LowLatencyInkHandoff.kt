package com.margelo.nitro.inksignpdf

import android.view.ViewGroup

internal enum class LowLatencyInkHandoffPhase {
  IDLE, FRONT_BUFFER_ACTIVE, FINAL_SNAPSHOT_PENDING, MULTI_BUFFER_PREPARED, HWUI_FRAME_COMMIT_PENDING,
  CLEARING_HIDDEN, RESTORED, DISPOSED,
}

internal data class LowLatencyInkHandoffDiagnostics(
  val phase: LowLatencyInkHandoffPhase,
  val requestedCount: Long,
  val finalSnapshotCount: Long,
  val multiBufferPreparedCount: Long,
  val completedHwuiFrameCount: Long,
  val clearingCount: Long,
  val overlayClearedCount: Long,
  val overlayRestoredCount: Long,
  val cancellationCount: Long,
  val staleCallbackCount: Long,
  val handoffDurationNanos: Long,
)

internal class LowLatencyInkHandoff(
  private val mainView: ViewGroup,
  private val surfaceView: android.view.SurfaceView,
  private val clearFrontBuffer: () -> Boolean,
  private val postOnAnimation: ((Runnable) -> Unit) = { mainView.postOnAnimation(it) },
  private val removeCallbacks: ((Runnable) -> Unit) = { mainView.removeCallbacks(it) },
  private val registerFrameCommit: ((Runnable) -> Unit) = {
    mainView.viewTreeObserver.registerFrameCommitCallback(it)
  },
) {
  private data class Token(val generation: Long, val sequence: Long)
  private var phase = LowLatencyInkHandoffPhase.IDLE
  private var token: Token? = null
  private var continuation: Runnable? = null
  private var requestedCount = 0L
  private var finalSnapshotCount = 0L
  private var multiBufferPreparedCount = 0L
  private var completedHwuiFrameCount = 0L
  private var clearingCount = 0L
  private var overlayClearedCount = 0L
  private var overlayRestoredCount = 0L
  private var cancellationCount = 0L
  private var staleCallbackCount = 0L
  private var startedAtNanos = 0L
  private var handoffDurationNanos = 0L

  fun onFrontBufferDrawAccepted(generation: Long, sequence: Long) {
    checkOnUiThread()
    if (phase == LowLatencyInkHandoffPhase.DISPOSED) return
    token = Token(generation, sequence)
    phase = LowLatencyInkHandoffPhase.FRONT_BUFFER_ACTIVE
  }

  fun requestHandoff(generation: Long, sequence: Long): Boolean {
    checkOnUiThread()
    if (phase == LowLatencyInkHandoffPhase.DISPOSED ||
      phase != LowLatencyInkHandoffPhase.FRONT_BUFFER_ACTIVE ||
      token != Token(generation, sequence)
    ) { staleCallbackCount += 1L; return false }
    requestedCount += 1L
    finalSnapshotCount += 1L
    phase = LowLatencyInkHandoffPhase.FINAL_SNAPSHOT_PENDING
    startedAtNanos = InkPerfetto.nowNanos()
    return true
  }

  fun onMultiBufferedLayerPrepared(generation: Long, sequence: Long) {
    checkOnUiThread()
    val expected = Token(generation, sequence)
    if (phase != LowLatencyInkHandoffPhase.FINAL_SNAPSHOT_PENDING || token != expected) {
      staleCallbackCount += 1L; return
    }
    phase = LowLatencyInkHandoffPhase.MULTI_BUFFER_PREPARED
    multiBufferPreparedCount += 1L
    InkPerfetto.counter("InkSign final multi-buffer transaction prepared", multiBufferPreparedCount)
    mainView.invalidate()
    registerFrameCommit callback@{
      checkOnUiThread()
      if (phase != LowLatencyInkHandoffPhase.MULTI_BUFFER_PREPARED || token != expected) {
        staleCallbackCount += 1L; return@callback
      }
      phase = LowLatencyInkHandoffPhase.HWUI_FRAME_COMMIT_PENDING
      completedHwuiFrameCount += 1L
      InkPerfetto.counter("InkSign completed HWUI frames", completedHwuiFrameCount)
      val next = Runnable { completeAfterFrame(expected) }
      continuation = next
      postOnAnimation(next)
    }
  }

  fun onMultiBufferedLayerFailed(generation: Long, sequence: Long): Boolean {
    checkOnUiThread()
    val expected = Token(generation, sequence)
    if (phase != LowLatencyInkHandoffPhase.FINAL_SNAPSHOT_PENDING || token != expected) {
      staleCallbackCount += 1L
      return false
    }
    cancel()
    return true
  }

  fun cancel(): Boolean {
    checkOnUiThread()
    if (phase == LowLatencyInkHandoffPhase.DISPOSED) return false
    val hadPresentation = phase != LowLatencyInkHandoffPhase.IDLE &&
      phase != LowLatencyInkHandoffPhase.RESTORED
    if (hadPresentation) cancellationCount += 1L
    continuation?.let(removeCallbacks)
    continuation = null
    if (hadPresentation) {
      phase = LowLatencyInkHandoffPhase.CLEARING_HIDDEN
      clearFrontBufferIfNeeded()
      restoreOverlay()
    }
    token = null
    phase = LowLatencyInkHandoffPhase.IDLE
    return hadPresentation
  }

  fun dispose() {
    checkOnUiThread()
    if (phase == LowLatencyInkHandoffPhase.DISPOSED) return
    cancel(); phase = LowLatencyInkHandoffPhase.DISPOSED
  }

  fun diagnostics(): LowLatencyInkHandoffDiagnostics = LowLatencyInkHandoffDiagnostics(
    phase, requestedCount, finalSnapshotCount, multiBufferPreparedCount,
    completedHwuiFrameCount, clearingCount, overlayClearedCount, overlayRestoredCount,
    cancellationCount, staleCallbackCount, handoffDurationNanos,
  )

  private fun completeAfterFrame(expected: Token) {
    checkOnUiThread(); continuation = null
    if (phase != LowLatencyInkHandoffPhase.HWUI_FRAME_COMMIT_PENDING || token != expected) {
      staleCallbackCount += 1L; return
    }
    phase = LowLatencyInkHandoffPhase.CLEARING_HIDDEN
    clearingCount += 1L
    clearFrontBufferIfNeeded(); restoreOverlay()
    phase = LowLatencyInkHandoffPhase.RESTORED
    handoffDurationNanos = (InkPerfetto.nowNanos() - startedAtNanos).coerceAtLeast(0L)
    startedAtNanos = 0L
  }

  private fun clearFrontBufferIfNeeded() { if (clearFrontBuffer()) overlayClearedCount += 1L }
  private fun restoreOverlay() {
    surfaceView.translationX = 0F; surfaceView.translationY = 0F
    mainView.invalidate(); overlayRestoredCount += 1L
  }
  private fun checkOnUiThread() {
    check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
  }
}
