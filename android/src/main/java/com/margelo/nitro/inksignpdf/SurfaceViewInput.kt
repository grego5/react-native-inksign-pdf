package com.margelo.nitro.inksignpdf

import android.view.MotionEvent

internal fun SurfaceView.handleEditEvent(event: MotionEvent) {
  if (event.flags and MotionEvent.FLAG_CANCELED != 0) {
    cancelActiveStroke()
    return
  }
  when (event.actionMasked) {
    MotionEvent.ACTION_DOWN -> beginStroke(event)
    MotionEvent.ACTION_MOVE -> moveStroke(event)
    MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
      if (event.actionMasked == MotionEvent.ACTION_POINTER_UP &&
        event.getPointerId(event.actionIndex) != activePointerId
      ) return
      endStroke(event)
    }
    MotionEvent.ACTION_CANCEL -> cancelActiveStroke()
    MotionEvent.ACTION_OUTSIDE -> cancelActiveStroke()
    MotionEvent.ACTION_POINTER_DOWN -> Unit
    else -> Unit
  }
}

private fun SurfaceView.beginStroke(event: MotionEvent) {
  if (activePointerId != SurfaceView.noPointer || event.pointerCount != 1) return
  val pointerIndex = event.actionIndex
  val toolType = event.getToolType(pointerIndex)
  if (!InkMotionEventSamples.isSupportedTool(toolType)) return
  if (!documentController.mapPagePoint(
      event.getX(pointerIndex), event.getY(pointerIndex), mappedPagePoint,
    )
  ) return
  if (!lowLatencyInk.isAvailable) {
    perfetto.marker("InkSign/front-buffer gesture rejected before native begin")
    InkPerfetto.instantMarker("InkSign/front-buffer presenter unavailable before begin")
    return
  }
  val logicalDisplayUnitsPerPageUnit =
    documentController.logicalDisplayUnitsPerPageUnit() ?: return
  val pagePen = pen.inPageUnits(logicalDisplayUnitsPerPageUnit)
  val configured = try {
    strokeEngine.configurePen(
      pagePen.minWidth,
      pagePen.maxWidth,
      pagePen.smoothing,
      logicalDisplayUnitsPerPageUnit,
    ) == StrokeEngine.STATUS_OK
  } catch (_: StrokeMutationException) {
    false
  }
  if (!configured) return
  traceRecorder.penConfiguration(
    pagePen.minWidth,
    pagePen.maxWidth,
    pagePen.smoothing,
    logicalDisplayUnitsPerPageUnit,
  )
  stopPrediction()
  perfetto.sampleReceived(event.eventTime)

  val nativeTime = event.eventTime.toDouble()
  val sampleTime = nativeTime * SurfaceView.millisToSeconds
  val samplePressure = InkMotionEventSamples.pressure(event, pointerIndex)
  val sampleAltitude = InkMotionEventSamples.altitude(event, pointerIndex)
  val sampleOrientation = InkMotionEventSamples.orientation(event, pointerIndex)
  val status = try {
    strokeEngine.beginAndRead(
      mappedPagePoint.x,
      mappedPagePoint.y,
      nativeTime,
      samplePressure,
      sampleAltitude,
      sampleOrientation,
    )
  } catch (_: StrokeMutationException) {
    return
  }
  perfetto.marker("InkSign/real committed")
  activePointerId = event.getPointerId(pointerIndex)
  activeToolType = toolType
  latestRealEventTimeMillis = event.eventTime
  beginFrontBufferStroke()
  traceRecorder.input(
    "down", sampleTime, mappedPagePoint.x, mappedPagePoint.y,
    samplePressure, sampleAltitude, sampleOrientation,
  )

  applyCommittedFrame(status)
  requestPredictionNow()
  if (!submitFrontBufferUpdate()) {
    cancelActiveStroke()
    return
  }
  invalidate()
}

private fun SurfaceView.moveStroke(event: MotionEvent) {
  if (!ensureFrontBufferAvailableDuringGesture()) return
  val pointerIndex = event.findPointerIndex(activePointerId)
  if (pointerIndex < 0) {
    cancelActiveStroke()
    return
  }
  val toolType = event.getToolType(pointerIndex)
  if (!InkMotionEventSamples.isSupportedTool(toolType)) {
    cancelActiveStroke()
    return
  }

  val stylus = toolType == MotionEvent.TOOL_TYPE_STYLUS
  val predictionWasVisible = stopPrediction()
  if (!prepareRealInputBatch(event, pointerIndex, stylus, terminal = false)) {
    if (predictionWasVisible && !submitFrontBufferUpdate()) cancelActiveStroke()
    return
  }
  val frame = try {
    strokeEngine.mutateRealBatchAndRead(
      StrokeEngine.BATCH_OPERATION_UPDATE,
      realInputBatch,
    )
  } catch (_: StrokeMutationException) {
    cancelActiveStroke()
    return
  }
  recordRealBatch(frame, realInputBatch.count)
  require(frame.type == StrokeFrameCodec.COMMITTED_TYPE) {
    "Move stroke mutation did not return a committed frame"
  }
  applyCommittedFrame(frame)
  requestPredictionNow()
  if (!submitFrontBufferUpdate()) {
    cancelActiveStroke()
    return
  }
  invalidate()
}

private fun SurfaceView.endStroke(event: MotionEvent) {
  if (!ensureFrontBufferAvailableDuringGesture()) return
  val pointerIndex = event.findPointerIndex(activePointerId)
  if (pointerIndex < 0) {
    cancelActiveStroke()
    return
  }
  val toolType = event.getToolType(pointerIndex)
  if (!InkMotionEventSamples.isSupportedTool(toolType)) {
    cancelActiveStroke()
    return
  }

  stopPrediction()
  val stylus = toolType == MotionEvent.TOOL_TYPE_STYLUS
  if (!prepareRealInputBatch(event, pointerIndex, stylus, terminal = true)) {
    cancelActiveStroke()
    return
  }
  val frame = try {
    strokeEngine.mutateRealBatchAndRead(
      StrokeEngine.BATCH_OPERATION_END,
      realInputBatch,
    )
  } catch (_: StrokeMutationException) {
    cancelActiveStroke()
    return
  }
  recordRealBatch(frame, realInputBatch.count)
  require(frame.type == StrokeFrameCodec.FINAL_TYPE) {
    "Terminal stroke mutation did not return a final frame"
  }
  val shouldHandoff = presentationSequence > 0L
  val handoffGeneration = presentationGeneration
  val handoffSequence = presentationSequence
  var finalSnapshot: LowLatencyInkFinalSnapshot? = null
  if (frame.contours.isNotEmpty()) {
    val outline = StrokeOutline.copyOf(frame.contours)
    // Final geometry becomes durable presentation/history state before the
    // replaceable front-buffer composition is discarded below.
    activeHistory().append(outline)
    inkRenderer.addCompletedOutline(outline)
    notifyStateChange()
    if (shouldHandoff) {
      val pageToView = documentController.pageToViewTransform()
      if (pageToView != null) {
        finalSnapshot = LowLatencyInkFinalSnapshot(
          generation = handoffGeneration,
          sequence = handoffSequence,
          paths = outline.contourPathData,
          pageToView = pageToView,
          color = pen.color,
          bufferWidth = width,
          bufferHeight = height,
        )
      }
    }
  }
  recordPresentationSummary()
  clearActivePresentation()
  activePointerId = SurfaceView.noPointer
  activeToolType = MotionEvent.TOOL_TYPE_UNKNOWN
  latestRealEventTimeMillis = null
  applyQueuedPen()
  invalidate()
  if (shouldHandoff) {
    val accepted = finalSnapshot?.let {
      lowLatencyInk.handoff(handoffGeneration, handoffSequence, it)
    } ?: false
    if (!accepted) invalidateFrontBufferPresentation()
  } else {
    invalidateFrontBufferPresentation()
  }
}

private fun SurfaceView.prepareRealInputBatch(
  event: MotionEvent,
  pointerIndex: Int,
  stylus: Boolean,
  terminal: Boolean,
): Boolean {
  if (event.historySize + 1 > RealInputBatch.MAX_INPUTS) {
    perfetto.marker("InkSign/real batch rejected: native bound exceeded")
    cancelActiveStroke()
    return false
  }
  realInputBatch.clear()
  for (historyPosition in 0 until event.historySize) {
    appendRealSample(event, pointerIndex, historyPosition, stylus, terminal = false)
  }
  val currentAccepted = appendRealSample(
    event, pointerIndex, InkMotionEventSamples.CURRENT_SAMPLE_POSITION,
    stylus, terminal,
  )
  if (terminal && !currentAccepted) return false
  return realInputBatch.count > 0
}

private fun SurfaceView.appendRealSample(
  event: MotionEvent,
  pointerIndex: Int,
  historyPosition: Int,
  stylus: Boolean,
  terminal: Boolean,
): Boolean {
  return InkMotionEventSamples.withMotionSample(
    event, pointerIndex, historyPosition,
  ) {
      x, y, eventTime, samplePressure, sampleTilt, sampleOrientation ->
    perfetto.sampleReceived(eventTime)
    if (!documentController.mapPagePoint(x, y, mappedPagePoint)) {
      return@withMotionSample false
    }
    val samplePressureValue =
      InkMotionEventSamples.normalizedPressure(samplePressure, stylus)
    val sampleAltitudeValue =
      InkMotionEventSamples.normalizedAltitude(sampleTilt, stylus)
    val sampleOrientationValue =
      InkMotionEventSamples.normalizedOrientation(sampleOrientation, stylus)
    if (!samplePressureValue.isFinite() || !sampleAltitudeValue.isFinite() ||
      !sampleOrientationValue.isFinite()
    ) {
      return@withMotionSample false
    }
    realInputBatch.add(
      mappedPagePoint.x,
      mappedPagePoint.y,
      eventTime.toDouble(),
      samplePressureValue,
      sampleAltitudeValue,
      sampleOrientationValue,
    )
    traceRecorder.input(
      if (terminal && historyPosition == InkMotionEventSamples.CURRENT_SAMPLE_POSITION) {
        "up"
      } else {
        "move"
      },
      eventTime.toDouble() * SurfaceView.millisToSeconds,
      mappedPagePoint.x,
      mappedPagePoint.y,
      samplePressureValue,
      sampleAltitudeValue,
      sampleOrientationValue,
    )
    latestRealEventTimeMillis = eventTime
    true
  }
}

private fun SurfaceView.recordRealBatch(frame: StrokeFrame, sampleCount: Int) {
  rawRealSampleCount += sampleCount.toLong()
  realBatchCount += 1L
  realNativeMutationCount += 1L
  realFrameCopyCount += 1L
  realFrameDecodeCount += 1L
  InkPerfetto.counter("InkSign raw real samples accepted", rawRealSampleCount)
  InkPerfetto.counter("InkSign real batch size", sampleCount)
  InkPerfetto.counter("InkSign real batch count", realBatchCount)
  InkPerfetto.counter("InkSign native real batch mutations", realNativeMutationCount)
  InkPerfetto.counter("InkSign real frame copies", realFrameCopyCount)
  InkPerfetto.counter("InkSign real frame decodes", realFrameDecodeCount)
  InkPerfetto.counter("InkSign C++ real model duration ns", frame.diagnostics.modelDurationNanos)
  InkPerfetto.counter("InkSign C++ real geometry duration ns", frame.diagnostics.geometryDurationNanos)
  perfetto.marker("InkSign/real batch accepted")
}

private fun SurfaceView.applyCommittedFrame(frame: StrokeFrame) {
  InkPerfetto.section("InkSign/apply frame") {
    frontBufferComposition.applyCommittedFrame(frame, presentationGeneration)
  }
}

private fun SurfaceView.ensureFrontBufferAvailableDuringGesture(): Boolean {
  if (activePointerId == SurfaceView.noPointer || lowLatencyInk.isAvailable) return true
  perfetto.marker("InkSign/front-buffer gesture cancelled: presenter unavailable")
  InkPerfetto.instantMarker("InkSign/front-buffer presenter lost during gesture")
  cancelActiveStroke()
  return false
}
