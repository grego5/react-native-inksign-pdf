package com.margelo.nitro.inksignpdf

import android.hardware.HardwareBuffer
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.FrameLayout
import androidx.graphics.lowlatency.CanvasFrontBufferedRenderer
import java.util.concurrent.atomic.AtomicLong

internal object LowLatencyInkRejectionReason {
  const val NONE = 0
  const val RENDERER_MISSING = 1
  const val RENDERER_INVALID = 2
  const val GENERATION_MISMATCH = 3
  const val STALE_SEQUENCE = 4
  const val LIFECYCLE_STATE = 5
}

internal object LowLatencyInkRendererCreationBlocker {
  const val NONE = 0
  const val PRESENTER_NOT_ATTACHED = 1
  const val SURFACE_UNAVAILABLE = 2
  const val WIDTH_ZERO = 3
  const val HEIGHT_ZERO = 4
  const val RENDERER_ALREADY_PRESENT = 5
  const val RELEASE_IN_PROGRESS = 6
  const val DISPOSED = 7
}

internal data class LowLatencyInkDiagnostics(
  val presenterState: Int,
  val rendererCreateCount: Int,
  val resetCount: Int,
  val cancelCount: Int,
  val releaseCount: Int,
  val handoff: LowLatencyInkHandoffDiagnostics,
  val rendererCreateSuccesses: Int,
  val invalidRendererCreations: Int,
  val rendererReleaseCompletions: Int,
  val overlayAttached: Boolean,
  val viewAttached: Boolean,
  val surfaceAvailable: Boolean,
  val surfaceValid: Boolean,
  val width: Int,
  val height: Int,
  val viewWidth: Int,
  val viewHeight: Int,
  val rendererPresent: Boolean,
  val rendererValid: Boolean,
  val creationBlocker: Int,
  val overlayAttachCount: Int,
  val overlayDetachCount: Int,
  val surfaceCreateCount: Int,
  val surfaceDestroyCount: Int,
  val sizeChangeCount: Int,
  val lastRejectionReason: Int,
  val rendererMissingRejections: Int,
  val rendererInvalidRejections: Int,
  val generationMismatchRejections: Int,
  val staleSequenceRejections: Int,
  val lifecycleStateRejections: Int,
  val acceptedSubmissionCount: Int,
  val rejectedSubmissionCount: Int,
  val payloads: LowLatencyInkPayloadDiagnostics,
)

/**
 * Small Google-style wrapper seam around the final AndroidX renderer.
 *
 * The callback is render-thread-only. AndroidX receives only a small immutable token; the
 * presenter-owned mailbox retains detached draw data until the worker callback completes.
 */
internal interface LowLatencyInkRenderer {
  fun isValid(): Boolean
  fun renderFrontBufferedLayer(token: LowLatencyInkRenderToken)
  fun commit()
  fun clear()
  fun cancel()
  fun release(cancelPending: Boolean, onReleaseComplete: () -> Unit)
}

internal fun interface LowLatencyInkRendererFactory {
  fun create(
    surfaceView: android.view.SurfaceView,
    callback: CanvasFrontBufferedRenderer.Callback<LowLatencyInkRenderToken>,
  ): LowLatencyInkRenderer
}

private class PlatformLowLatencyInkRendererFactory : LowLatencyInkRendererFactory {
  override fun create(
    surfaceView: android.view.SurfaceView,
    callback: CanvasFrontBufferedRenderer.Callback<LowLatencyInkRenderToken>,
  ): LowLatencyInkRenderer {
    return PlatformLowLatencyInkRenderer(
      CanvasFrontBufferedRenderer(
        surfaceView,
        callback,
        HardwareBuffer.RGBA_8888,
      ),
    )
  }
}

private class PlatformLowLatencyInkRenderer(
  private val delegate: CanvasFrontBufferedRenderer<LowLatencyInkRenderToken>,
) : LowLatencyInkRenderer {
  override fun isValid(): Boolean = delegate.isValid()

  override fun renderFrontBufferedLayer(token: LowLatencyInkRenderToken) {
    delegate.renderFrontBufferedLayer(token)
  }

  override fun commit() {
    delegate.commit()
  }

  override fun clear() {
    delegate.clear()
  }

  override fun cancel() {
    delegate.cancel()
  }

  override fun release(cancelPending: Boolean, onReleaseComplete: () -> Unit) {
    delegate.release(cancelPending, onReleaseComplete)
  }
}

/**
 * UI-thread owner for the inactive front-buffer host.
 *
 * A renderer is created only after attachment, a real Surface, and usable
 * dimensions exist. Surface destruction and host detachment release it; a
 * later recreation waits for asynchronous release completion before creating
 * exactly one fresh renderer.
 */
internal class LowLatencyInkPresenter(
  context: android.content.Context,
  private val rendererFactory: LowLatencyInkRendererFactory =
    PlatformLowLatencyInkRendererFactory(),
  private val mainView: android.view.ViewGroup = FrameLayout(context),
  private val surfaceValidity: (LowLatencyInkView) -> Boolean =
    { view -> view.holder.surface.isValid },
  private val beforeDiagnosticsPublish: () -> Unit = {},
) : LowLatencyInkView.Listener, LowLatencyInkHost {
  private enum class State(val code: Int) {
    HOST_UNATTACHED(0),
    ATTACHED(1),
    RELEASING(2),
    DISPOSED(3),
  }

  private companion object {
    const val LOG_TAG = "InkSignFrontBuffer"
  }

  private val mainHandler = Handler(Looper.getMainLooper())
  private var overlay: LowLatencyInkView? = LowLatencyInkView(context, this)
  private var renderer: LowLatencyInkRenderer? = null
  private var state = State.HOST_UNATTACHED
  private var hostAttached = false
  private var surfaceAvailable = false
  private var width = 0
  private var height = 0
  private var releaseSerial = 0L
  private var rendererCreateCount = 0
  private var resetCount = 0
  private var cancelCount = 0
  private var releaseCount = 0
  private var rendererCreateSuccesses = 0
  private var invalidRendererCreations = 0
  private var rendererReleaseCompletions = 0
  private var creationBlocker = LowLatencyInkRendererCreationBlocker.PRESENTER_NOT_ATTACHED
  private var overlayAttachCount = 0
  private var overlayDetachCount = 0
  private var surfaceCreateCount = 0
  private var surfaceDestroyCount = 0
  private var sizeChangeCount = 0
  private var rendererValidityRecorded = false
  private var lastRejectionReason = LowLatencyInkRejectionReason.NONE
  private var rendererMissingRejections = 0
  private var rendererInvalidRejections = 0
  private var generationMismatchRejections = 0
  private var staleSequenceRejections = 0
  private var lifecycleStateRejections = 0
  private var acceptedSubmissionCount = 0
  private var rejectedSubmissionCount = 0
  private var lastAcknowledgedSequence = 0L
  private var acknowledgementListener:
    (LowLatencyInkPresentationAcknowledgement) -> Unit = {}
  private var lifecycleCancellationListener: () -> Unit = {}
  private val payloads = LowLatencyInkPayloadMailbox()
  private val finalSnapshots = java.util.concurrent.ConcurrentHashMap<LowLatencyInkRenderToken, LowLatencyInkFinalSnapshot>()
  private var frontBufferMayContainPixels = false
  private val requestGeneration = AtomicLong(0L)
  private val latestSubmittedSequence = AtomicLong(0L)
  private val lastConsumedSequence = AtomicLong(0L)
  private var drawCallback: LowLatencyInkDrawCallback? = null
  private val handoff = LowLatencyInkHandoff(
    mainView = mainView,
    surfaceView = checkNotNull(overlay),
    clearFrontBuffer = ::clearFrontBufferAfterHandoff,
  )

  val view: LowLatencyInkView
    get() = checkNotNull(overlay) { "Front-buffer overlay has been disposed" }

  override val isAvailable: Boolean
    get() = renderer?.isValid() == true

  override fun setPresentationAcknowledgementListener(
    listener: (LowLatencyInkPresentationAcknowledgement) -> Unit,
  ) {
    checkOnUiThread()
    acknowledgementListener = listener
  }

  override fun setLifecycleCancellationListener(listener: () -> Unit) {
    checkOnUiThread()
    lifecycleCancellationListener = listener
  }

  override fun onOverlayAttached(view: LowLatencyInkView) {
    checkOnUiThread()
    if (state == State.DISPOSED) return
    check(view === overlay)
    hostAttached = true
    overlayAttachCount += 1
    if (state != State.RELEASING) state = State.ATTACHED
    reportLifecycle("overlay attached", "InkSign/front-buffer overlay attached")
    maybeCreateRenderer()
  }

  override fun onOverlayDetached(view: LowLatencyInkView) {
    checkOnUiThread()
    if (state == State.DISPOSED) return
    check(view === overlay)
    hostAttached = false
    surfaceAvailable = false
    if (state != State.RELEASING) state = State.HOST_UNATTACHED
    overlayDetachCount += 1
    reportLifecycle("overlay detached", "InkSign/front-buffer overlay detached")
    releaseRenderer()
    lifecycleCancellationListener()
  }

  override fun onOverlaySurfaceCreated(view: LowLatencyInkView) {
    checkOnUiThread()
    if (state == State.DISPOSED) return
    check(view === overlay)
    surfaceAvailable = true
    surfaceCreateCount += 1
    synchronizeStoredSize(view)
    restoreAttachedStateIfReady()
    reportLifecycle("surface created", "InkSign/front-buffer surface created")
    maybeCreateRenderer()
  }

  override fun onOverlaySurfaceDestroyed(view: LowLatencyInkView) {
    checkOnUiThread()
    if (state == State.DISPOSED) return
    check(view === overlay)
    surfaceAvailable = false
    surfaceDestroyCount += 1
    reportLifecycle("surface destroyed", "InkSign/front-buffer surface destroyed")
    releaseRenderer()
    lifecycleCancellationListener()
  }

  override fun onOverlaySizeChanged(view: LowLatencyInkView, width: Int, height: Int) {
    checkOnUiThread()
    if (state == State.DISPOSED) return
    check(view === overlay)
    this.width = width
    this.height = height
    sizeChangeCount += 1
    restoreAttachedStateIfReady()
    reportLifecycle("size changed", "InkSign/front-buffer size changed")
    maybeCreateRenderer()
  }

  /** Reconcile a framework attach callback with the actual overlay state. */
  fun synchronizeLifecycleFromFramework() {
    checkOnUiThread()
    val current = overlay ?: return
    if (current.isAttachedToWindow && !hostAttached) {
      onOverlayAttached(current)
    } else if (!current.isAttachedToWindow && hostAttached) {
      onOverlayDetached(current)
      return
    }
    val actualSurfaceAvailable = surfaceValidity(current)
    if (actualSurfaceAvailable && !surfaceAvailable) {
      onOverlaySurfaceCreated(current)
    } else if (!actualSurfaceAvailable && surfaceAvailable) {
      onOverlaySurfaceDestroyed(current)
      return
    }
    if (current.width != width || current.height != height) {
      onOverlaySizeChanged(current, current.width, current.height)
    }
    reportLifecycle("framework state synchronized")
  }

  /** Submit one bounded modified-region request using preserved front-buffer rendering. */
  override fun requestDraw(update: LowLatencyInkDrawRequest): Boolean {
    checkOnUiThread()
    if (state == State.DISPOSED || state == State.RELEASING) {
      return reject(
        LowLatencyInkRejectionReason.LIFECYCLE_STATE,
        "InkSign/front-buffer rejected presenter releasing or disposed",
        update,
      )
    }
    val current = renderer ?: return reject(
      LowLatencyInkRejectionReason.RENDERER_MISSING,
      "InkSign/front-buffer rejected renderer missing",
      update,
    )
    if (!observeRendererValidity(current)) {
      return reject(
        LowLatencyInkRejectionReason.RENDERER_INVALID,
        "InkSign/front-buffer rejected renderer invalid",
        update,
      )
    }
    if (update.generation != requestGeneration.get()) {
      return reject(
        LowLatencyInkRejectionReason.GENERATION_MISMATCH,
        "InkSign/front-buffer rejected generation mismatch",
        update,
      )
    }
    if (update.sequence <= latestSubmittedSequence.get()) {
      return reject(
        LowLatencyInkRejectionReason.STALE_SEQUENCE,
        "InkSign/front-buffer rejected stale sequence",
        update,
      )
    }
    latestSubmittedSequence.set(update.sequence)
    val token = payloads.publish(update)
    acceptedSubmissionCount += 1
    lastRejectionReason = LowLatencyInkRejectionReason.NONE
    InkPerfetto.counter(
      "InkSign front-buffer accepted submissions",
      acceptedSubmissionCount,
    )
    reportLifecycle("request accepted")
    InkPerfetto.section("InkSign/front-buffer submit requested") {
      try {
        current.renderFrontBufferedLayer(token)
      } catch (error: Throwable) {
        payloads.discardPending(token)
        InkPerfetto.endAsyncUpdate(token.sequence)
        throw error
      }
    }
    InkPerfetto.counter("InkSign front-buffer submit sequence", update.sequence)
    handoff.onFrontBufferDrawAccepted(update.generation, update.sequence)
    frontBufferMayContainPixels = true
    return true
  }

  override fun handoff(
    generation: Long,
    sequence: Long,
    finalSnapshot: LowLatencyInkFinalSnapshot,
  ): Boolean {
    checkOnUiThread()
    if (finalSnapshot.generation != generation || finalSnapshot.sequence != sequence) return false
    val current = renderer ?: return false
    if (!current.isValid() || generation != requestGeneration.get()) return false
    val token = LowLatencyInkRenderToken(generation, sequence)
    if (!handoff.requestHandoff(generation, sequence)) {
      return false
    }
    return try {
      finalSnapshots.clear()
      finalSnapshots[token] = finalSnapshot
      drawCallback?.installFinalSnapshot(token)
      current.commit()
      true
    } catch (error: Throwable) {
      handoff.cancel()
      finalSnapshots.remove(token)
      throw error
    }
  }

  override fun resetActive(generation: Long) {
    checkOnUiThread()
    val retiredGeneration = requestGeneration.get()
    requestGeneration.set(generation)
    latestSubmittedSequence.set(0L)
    lastConsumedSequence.set(0L)
    lastAcknowledgedSequence = 0L
    payloads.clear()
    finalSnapshots.clear()
    drawCallback?.clearFinalSnapshot()
    cancelAndClearFrontBuffer(retiredGeneration)
  }

  fun clear() {
    checkOnUiThread()
    val retiredGeneration = invalidateRequests()
    cancelAndClearFrontBuffer(retiredGeneration)
  }

  override fun drawDiagnostics(): LowLatencyInkDrawDiagnostics? {
    checkOnUiThread()
    return drawCallback?.diagnostics()
  }

  override fun handoffDiagnostics(): LowLatencyInkHandoffDiagnostics {
    checkOnUiThread()
    return handoff.diagnostics()
  }

  fun diagnostics(): LowLatencyInkDiagnostics {
    checkOnUiThread()
    renderer?.let(::observeRendererValidity)
    val handoffDiagnostics = handoff.diagnostics()
    val currentView = overlay
    val actualViewAttached = currentView?.isAttachedToWindow == true
    val actualSurfaceValid = currentView?.let(surfaceValidity) == true
    val actualViewWidth = currentView?.width ?: 0
    val actualViewHeight = currentView?.height ?: 0
    return LowLatencyInkDiagnostics(
      state.code,
      rendererCreateCount,
      resetCount,
      cancelCount,
      releaseCount,
      handoffDiagnostics,
      rendererCreateSuccesses,
      invalidRendererCreations,
      rendererReleaseCompletions,
      overlayAttached = hostAttached,
      viewAttached = actualViewAttached,
      surfaceAvailable,
      surfaceValid = actualSurfaceValid,
      width,
      height,
      viewWidth = actualViewWidth,
      viewHeight = actualViewHeight,
      rendererPresent = renderer != null,
      rendererValid = renderer?.isValid() == true,
      creationBlocker,
      overlayAttachCount,
      overlayDetachCount,
      surfaceCreateCount,
      surfaceDestroyCount,
      sizeChangeCount,
      lastRejectionReason,
      rendererMissingRejections,
      rendererInvalidRejections,
      generationMismatchRejections,
      staleSequenceRejections,
      lifecycleStateRejections,
      acceptedSubmissionCount,
      rejectedSubmissionCount,
      payloads = payloads.diagnostics(),
    )
  }

  /** Release the overlay and reject all future renderer operations permanently. */
  fun release() {
    checkOnUiThread()
    if (state == State.DISPOSED) return
    hostAttached = false
    state = State.DISPOSED
    surfaceAvailable = false
    creationBlocker = LowLatencyInkRendererCreationBlocker.DISPOSED
    reportLifecycle("presenter disposed", "InkSign/front-buffer presenter disposed")
    handoff.dispose()
    lifecycleCancellationListener = {}
    acknowledgementListener = {}
    invalidateRequests()
    finalSnapshots.clear()
    releaseRenderer()
    overlay?.let { view ->
      view.holder.removeCallback(view)
      (view.parent as? android.view.ViewGroup)?.removeView(view)
    }
    overlay = null
  }

  private fun maybeCreateRenderer() {
    checkOnUiThread()
    val blocker = when {
      state == State.DISPOSED -> LowLatencyInkRendererCreationBlocker.DISPOSED
      state == State.RELEASING -> LowLatencyInkRendererCreationBlocker.RELEASE_IN_PROGRESS
      state != State.ATTACHED || !hostAttached ->
        LowLatencyInkRendererCreationBlocker.PRESENTER_NOT_ATTACHED
      !surfaceAvailable || overlay?.let(surfaceValidity) != true ->
        LowLatencyInkRendererCreationBlocker.SURFACE_UNAVAILABLE
      width <= 0 -> LowLatencyInkRendererCreationBlocker.WIDTH_ZERO
      height <= 0 -> LowLatencyInkRendererCreationBlocker.HEIGHT_ZERO
      renderer != null -> LowLatencyInkRendererCreationBlocker.RENDERER_ALREADY_PRESENT
      else -> LowLatencyInkRendererCreationBlocker.NONE
    }
    creationBlocker = blocker
    if (blocker != LowLatencyInkRendererCreationBlocker.NONE) {
      val marker = when (blocker) {
        LowLatencyInkRendererCreationBlocker.PRESENTER_NOT_ATTACHED ->
          "InkSign/front-buffer create blocked unattached"
        LowLatencyInkRendererCreationBlocker.SURFACE_UNAVAILABLE ->
          "InkSign/front-buffer create blocked surface unavailable"
        LowLatencyInkRendererCreationBlocker.WIDTH_ZERO,
        LowLatencyInkRendererCreationBlocker.HEIGHT_ZERO ->
          "InkSign/front-buffer create blocked zero size"
        LowLatencyInkRendererCreationBlocker.RENDERER_ALREADY_PRESENT ->
          "InkSign/front-buffer create blocked renderer already present"
        LowLatencyInkRendererCreationBlocker.RELEASE_IN_PROGRESS ->
          "InkSign/front-buffer create blocked release pending"
        LowLatencyInkRendererCreationBlocker.DISPOSED ->
          "InkSign/front-buffer create blocked disposed"
        else -> null
      }
      reportLifecycle("renderer creation blocked", marker)
      return
    }

    rendererCreateCount += 1
    reportLifecycle("renderer creation attempted", "InkSign/front-buffer renderer creation attempted")
    val drawCallback = LowLatencyInkDrawCallback(
      requestGeneration,
      lastConsumedSequence,
      payloads,
      acknowledgeOnUi = ::onFrontBufferRenderAcknowledged,
      mainHandler = mainHandler,
      finalSnapshotFor = { token -> finalSnapshots[token] },
      beforeDiagnosticsPublish = beforeDiagnosticsPublish,
      onMultiBufferedLayerPrepared = { generation, sequence, prepared ->
        mainHandler.post { onMultiBufferedLayerPrepared(generation, sequence, prepared) }
      },
    )
    val created = try {
      rendererFactory.create(view, drawCallback)
    } catch (error: Throwable) {
      Log.e(LOG_TAG, "InkSignFrontBuffer event=renderer construction failed", error)
      throw error
    }
    renderer = created
    this.drawCallback = drawCallback
    rendererValidityRecorded = false
    reportLifecycle("renderer created", "InkSign/front-buffer renderer created")
    if (!observeRendererValidity(created)) {
      invalidRendererCreations += 1
      InkPerfetto.counter(
        "InkSign front-buffer renderer invalid creations",
        invalidRendererCreations,
      )
      Log.w(LOG_TAG, "InkSignFrontBuffer event=renderer invalid after construction")
      InkPerfetto.instantMarker("InkSign/front-buffer renderer initially invalid")
      reportLifecycle("renderer invalid", "InkSign/front-buffer renderer invalid")
    }
  }

  private fun releaseRenderer() {
    checkOnUiThread()
    val current = renderer ?: return
    invalidateRequests()
    if (current.isValid()) {
      current.cancel()
      cancelCount += 1
    }
    handoff.cancel()
    renderer = null
    drawCallback = null
    rendererValidityRecorded = false
    state = if (state == State.DISPOSED) State.DISPOSED else State.RELEASING
    releaseCount += 1
    if (state != State.DISPOSED) {
      creationBlocker = LowLatencyInkRendererCreationBlocker.RELEASE_IN_PROGRESS
    }
    reportLifecycle("renderer release started", "InkSign/front-buffer renderer release started")
    val serial = ++releaseSerial
    current.release(cancelPending = true) {
      mainHandler.post {
        rendererReleaseCompletions += 1
        InkPerfetto.counter(
          "InkSign front-buffer renderer release completions",
          rendererReleaseCompletions,
        )
        InkPerfetto.instantMarker("InkSign/front-buffer renderer release completed")
        reportLifecycle("renderer release completed")
        if (serial != releaseSerial || state == State.DISPOSED) return@post
        state = if (hostAttached && surfaceAvailable) State.ATTACHED else State.HOST_UNATTACHED
        maybeCreateRenderer()
      }
    }
  }

  private fun invalidateRequests(): Long {
    val retiredGeneration = requestGeneration.getAndIncrement()
    latestSubmittedSequence.set(0L)
    lastConsumedSequence.set(0L)
    lastAcknowledgedSequence = 0L
    payloads.clear()
    finalSnapshots.clear()
    drawCallback?.clearFinalSnapshot()
    return retiredGeneration
  }

  /** Runs on the main thread after AndroidX prepared the replacement transaction. */
  private fun onFrontBufferRenderAcknowledged(
    acknowledgement: LowLatencyInkPresentationAcknowledgement,
  ) {
    checkOnUiThread()
    if (acknowledgement.generation != requestGeneration.get()) return
    if (acknowledgement.sequence <= lastAcknowledgedSequence) return
    if (acknowledgement.sequence > latestSubmittedSequence.get()) return
    lastAcknowledgedSequence = acknowledgement.sequence
    acknowledgementListener(acknowledgement)
  }

  /** Re-enter the attached state after asynchronous Surface release/recreation. */
  private fun restoreAttachedStateIfReady() {
    if (state == State.HOST_UNATTACHED && hostAttached) {
      state = State.ATTACHED
    }
  }

  /** Cancel queued callbacks before clearing the retained front-buffer pixels. */
  private fun cancelAndClearFrontBuffer(retiredGeneration: Long) {
    val current = renderer
    if (current?.isValid() == true) {
      current.cancel()
      cancelCount += 1
    }
    val hadPresentation = handoff.cancel()
    if (!hadPresentation && frontBufferMayContainPixels && current?.isValid() == true) {
      // Preserve the existing clear/reset contract when transient pixels were presented.
      drawCallback?.enqueueFinalClear(retiredGeneration)
      current.clear()
      resetCount += 1
    }
    frontBufferMayContainPixels = false
  }

  private fun checkOnUiThread() {
    check(Looper.myLooper() == Looper.getMainLooper())
  }

  private fun observeRendererValidity(current: LowLatencyInkRenderer): Boolean {
    val valid = current.isValid()
    if (valid && !rendererValidityRecorded) {
      rendererValidityRecorded = true
      rendererCreateSuccesses += 1
      InkPerfetto.counter(
        "InkSign front-buffer renderer create successes",
        rendererCreateSuccesses,
      )
      InkPerfetto.instantMarker("InkSign/front-buffer renderer became valid")
      reportLifecycle("renderer became valid")
    }
    return valid
  }

  private fun reject(
    reason: Int,
    marker: String,
    request: LowLatencyInkDrawRequest,
  ): Boolean {
    lastRejectionReason = reason
    rejectedSubmissionCount += 1
    val reasonCount = when (reason) {
      LowLatencyInkRejectionReason.RENDERER_MISSING -> {
        rendererMissingRejections += 1
        rendererMissingRejections
      }
      LowLatencyInkRejectionReason.RENDERER_INVALID -> {
        rendererInvalidRejections += 1
        rendererInvalidRejections
      }
      LowLatencyInkRejectionReason.GENERATION_MISMATCH -> {
        generationMismatchRejections += 1
        generationMismatchRejections
      }
      LowLatencyInkRejectionReason.STALE_SEQUENCE -> {
        staleSequenceRejections += 1
        staleSequenceRejections
      }
      LowLatencyInkRejectionReason.LIFECYCLE_STATE -> {
        lifecycleStateRejections += 1
        lifecycleStateRejections
      }
      else -> 0
    }
    InkPerfetto.counter("InkSign front-buffer rejection reason", reason)
    InkPerfetto.counter("InkSign front-buffer rejected count", rejectedSubmissionCount)
    InkPerfetto.counter(
      "InkSign front-buffer rejection generation",
      request.generation,
    )
    InkPerfetto.counter(
      "InkSign front-buffer rejection expected generation",
      requestGeneration.get(),
    )
    InkPerfetto.counter(
      "InkSign front-buffer rejection sequence",
      request.sequence,
    )
    InkPerfetto.counter(
      "InkSign front-buffer rejection latest sequence",
      latestSubmittedSequence.get(),
    )
    InkPerfetto.counter(
      "InkSign front-buffer rejection reason $reason count",
      reasonCount,
    )
    InkPerfetto.instantMarker(marker)
    Log.w(
      LOG_TAG,
      "InkSignFrontBuffer event=request rejected reason=$reason " +
        "requestGeneration=${request.generation} expectedGeneration=${requestGeneration.get()} " +
        "requestSequence=${request.sequence} latestSubmittedSequence=${latestSubmittedSequence.get()}",
    )
    reportLifecycle("request rejected")
    return false
  }

  private fun reportLifecycle(event: String, marker: String? = null) {
    val currentView = overlay
    val actualViewAttached = currentView?.isAttachedToWindow == true
    val actualSurfaceValid = currentView?.let(surfaceValidity) == true
    val actualViewWidth = currentView?.width ?: 0
    val actualViewHeight = currentView?.height ?: 0
    val rendererValid = renderer?.isValid() == true
    InkPerfetto.counter("InkSign front-buffer presenter state", state.code)
    InkPerfetto.counter("InkSign front-buffer overlay attached", if (hostAttached) 1 else 0)
    InkPerfetto.counter("InkSign front-buffer view attached", if (actualViewAttached) 1 else 0)
    InkPerfetto.counter("InkSign front-buffer surface available", if (surfaceAvailable) 1 else 0)
    InkPerfetto.counter("InkSign front-buffer surface valid", if (actualSurfaceValid) 1 else 0)
    InkPerfetto.counter("InkSign front-buffer surface width", width)
    InkPerfetto.counter("InkSign front-buffer surface height", height)
    InkPerfetto.counter("InkSign front-buffer view width", actualViewWidth)
    InkPerfetto.counter("InkSign front-buffer view height", actualViewHeight)
    InkPerfetto.counter("InkSign front-buffer renderer present", if (renderer != null) 1 else 0)
    InkPerfetto.counter("InkSign front-buffer renderer valid", if (rendererValid) 1 else 0)
    InkPerfetto.counter("InkSign front-buffer creation blocker", creationBlocker)
    InkPerfetto.counter("InkSign front-buffer renderer create attempts", rendererCreateCount)
    InkPerfetto.counter("InkSign front-buffer renderer create successes", rendererCreateSuccesses)
    InkPerfetto.counter("InkSign front-buffer renderer invalid creations", invalidRendererCreations)
    InkPerfetto.counter("InkSign front-buffer overlay attach count", overlayAttachCount)
    InkPerfetto.counter("InkSign front-buffer overlay detach count", overlayDetachCount)
    InkPerfetto.counter("InkSign front-buffer surface create count", surfaceCreateCount)
    InkPerfetto.counter("InkSign front-buffer surface destroy count", surfaceDestroyCount)
    InkPerfetto.counter("InkSign front-buffer size change count", sizeChangeCount)
    InkPerfetto.counter("InkSign front-buffer release starts", releaseCount)
    InkPerfetto.counter("InkSign front-buffer renderer release completions", rendererReleaseCompletions)
    InkPerfetto.counter("InkSign front-buffer rejection reason", lastRejectionReason)
    marker?.let(InkPerfetto::instantMarker)
  }

  private fun synchronizeStoredSize(view: LowLatencyInkView) {
    if (view.width <= 0 || view.height <= 0) return
    if (width == view.width && height == view.height) return
    width = view.width
    height = view.height
    sizeChangeCount += 1
    reportLifecycle("surface created size synchronized")
  }

  private fun clearFrontBufferAfterHandoff(): Boolean {
    checkOnUiThread()
    val current = renderer ?: return false
    if (!current.isValid()) return false
    drawCallback?.enqueueFinalClear(requestGeneration.get())
    current.clear()
    drawCallback?.clearFinalSnapshot()
    payloads.clear()
    finalSnapshots.clear()
    resetCount += 1
    frontBufferMayContainPixels = false
    return true
  }

  private fun onMultiBufferedLayerPrepared(
    generation: Long,
    sequence: Long,
    prepared: Boolean,
  ) {
    checkOnUiThread()
    if (prepared) {
      handoff.onMultiBufferedLayerPrepared(generation, sequence)
    } else {
      if (handoff.onMultiBufferedLayerFailed(generation, sequence)) {
        finalSnapshots.remove(LowLatencyInkRenderToken(generation, sequence))
      }
    }
  }
}
