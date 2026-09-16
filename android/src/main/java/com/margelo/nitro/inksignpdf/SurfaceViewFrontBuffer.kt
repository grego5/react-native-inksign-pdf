package com.margelo.nitro.inksignpdf

import android.view.MotionEvent

internal fun SurfaceView.beginFrontBufferStroke() {
  presentationGeneration += 1L
  presentationSequence = 0L
  previousFrontBufferBounds = null
  pendingFrontBufferDirtyRegion = null
  latestFrontBufferAcknowledgedSequence = 0L
  frontBufferComposition.reset(presentationGeneration)
  acceptsFrontBufferAcknowledgements = true
  lowLatencyInk.resetActive(presentationGeneration)
  fullResetCount += 1L
  InkPerfetto.counter("InkSign front-buffer full resets", fullResetCount)
}

internal fun SurfaceView.submitFrontBufferUpdate(): Boolean {
  if (!lowLatencyInk.isAvailable) {
    perfetto.marker("InkSign/front-buffer presenter unavailable during gesture")
    return false
  }
  val pageToView = documentController.pageToViewTransform() ?: return false
  val viewWidth = width
  val viewHeight = height
  presentationSequence += 1L
  val currentBounds = frontBufferComposition.frontBufferBounds()
  val request = InkPerfetto.section("InkSign/dirty region update request") {
    frontBufferComposition.buildFrontBufferRequest(
      generation = presentationGeneration,
      sequence = presentationSequence,
      previousBounds = previousFrontBufferBounds,
      pageToView = pageToView,
      viewWidth = viewWidth,
      viewHeight = viewHeight,
      color = pen.color,
      dirtyRegionOverride = pendingFrontBufferDirtyRegion,
    )
  }.copy(
    eventAgeAtDeliveryMillis = eventAgeAtDeliveryMillis,
    submitRequestedAtNanos = InkPerfetto.nowNanos(),
  )
  dirtyRegionAreaPixels +=
    (request.dirtyRegion.right - request.dirtyRegion.left).toLong() *
      (request.dirtyRegion.bottom - request.dirtyRegion.top).toLong()
  dirtyRegionOutsetPx = request.dirtyRegionOutsetPx
  changedGeometryCount += request.changedGeometryCount
  copiedGeometryCount += request.copiedGeometryCount
  changedEventCount += 1L
  incrementalRequestCount += 1L
  InkPerfetto.beginAsyncUpdate(request.sequence)
  pendingFrontBufferDirtyRegion = pendingFrontBufferDirtyRegion?.union(request.dirtyRegion)
    ?: request.dirtyRegion
  val accepted = lowLatencyInk.requestDraw(request)
  if (!accepted) {
    pendingFrontBufferDirtyRegion = null
    InkPerfetto.endAsyncUpdate(request.sequence)
  }
  if (accepted) acceptedRequestCount += 1L else rejectedRequestCount += 1L
  if (accepted) {
    previousFrontBufferBounds = LowLatencyInkBoundsSnapshot(
      liveTail = currentBounds.liveTail,
      prediction = currentBounds.prediction,
      newlyStable = null,
    )
  }
  InkPerfetto.counter("InkSign front-buffer changed events", changedEventCount)
  InkPerfetto.counter("InkSign front-buffer incremental requests", incrementalRequestCount)
  InkPerfetto.counter("InkSign front-buffer accepted requests", acceptedRequestCount)
  InkPerfetto.counter("InkSign front-buffer rejected requests", rejectedRequestCount)
  InkPerfetto.counter("InkSign dirty region area px", dirtyRegionAreaPixels)
  InkPerfetto.counter("InkSign changed geometry count", changedGeometryCount)
  InkPerfetto.counter("InkSign copied geometry count", copiedGeometryCount)
  val rolling = frontBufferComposition.retainedDiagnostics()
  InkPerfetto.counter(
    "InkSign retained rolling committed contours",
    rolling.committedContourCount,
  )
  InkPerfetto.counter(
    "InkSign retained rolling predicted contours",
    rolling.predictionContourCount,
  )
  return accepted
}

internal fun SurfaceView.invalidateFrontBufferPresentation() {
  presentationGeneration += 1L
  presentationSequence = 0L
  previousFrontBufferBounds = null
  pendingFrontBufferDirtyRegion = null
  latestFrontBufferAcknowledgedSequence = 0L
  lowLatencyInk.resetActive(presentationGeneration)
}

internal fun SurfaceView.clearActivePresentation() {
  acceptsFrontBufferAcknowledgements = false
  stopPrediction()
  frontBufferComposition.clear()
  pendingFrontBufferDirtyRegion = null
  previousFrontBufferBounds = null
}

internal fun SurfaceView.cancelActiveStroke(
  cancelEngineWhenIdle: Boolean = false,
  cancellationReason: Int = SurfaceView.CANCELLATION_INPUT,
) {
  val wasActive = activePointerId != SurfaceView.noPointer
  if (wasActive) {
    cancelledCount += 1L
    lastCancellationReason = cancellationReason
    InkPerfetto.counter("InkSign cancellation reason", cancellationReason)
  }
  if (wasActive) {
    activePointerId = SurfaceView.noPointer
    activeToolType = MotionEvent.TOOL_TYPE_UNKNOWN
    latestRealEventTimeMillis = null
    strokeEngine.cancel()
    traceRecorder.cancel()
    clearActivePresentation()
  } else {
    if (cancelEngineWhenIdle) strokeEngine.cancel()
  }
  invalidateFrontBufferPresentation()
  applyQueuedPen()
  if (!wasActive) return
  invalidate()
}
