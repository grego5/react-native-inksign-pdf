package com.margelo.nitro.inksignpdf

import android.view.MotionEvent

internal fun ViewerCanvas.handleEditEvent(event: MotionEvent) {
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

private fun ViewerCanvas.beginStroke(event: MotionEvent) {
  if (activePointerId != ViewerCanvas.noPointer || event.pointerCount != 1) return
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
  val viewToPage = documentController.historyToViewTransform()?.inverse() ?: return
  stylusSampleFrame.begin(event, pointerIndex, viewToPage)
  val samplePressure = stylusSampleFrame.pressure(event.getPressure(pointerIndex))
  val sampleTilt = stylusSampleFrame.tilt(
    event.getAxisValue(MotionEvent.AXIS_TILT, pointerIndex),
  )
  val sampleOrientation = stylusSampleFrame.orientation(
    event.getAxisValue(MotionEvent.AXIS_ORIENTATION, pointerIndex),
  )
  if (!samplePressure.isFinite() || !sampleTilt.isFinite() || !sampleOrientation.isFinite()) {
    return
  }
  val pagePen = pen.inPageUnits(logicalDisplayUnitsPerPageUnit)
  val configured = try {
    inkEngine.configurePen(
      pagePen.minWidth,
      pagePen.maxWidth,
      pagePen.smoothing,
      logicalDisplayUnitsPerPageUnit,
    ) == InkEngine.STATUS_OK
  } catch (_: InkStrokeMutationException) {
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
  val sampleTime = nativeTime * ViewerCanvas.millisToSeconds
  val status = try {
    inkEngine.beginAndRead(
      mappedPagePoint.x,
      mappedPagePoint.y,
      nativeTime,
      samplePressure,
      sampleTilt,
      sampleOrientation,
    )
  } catch (_: InkStrokeMutationException) {
    return
  }
  perfetto.marker("InkSign/real committed")
  activePointerId = event.getPointerId(pointerIndex)
  activeToolType = toolType
  latestRealEventTimeMillis = event.eventTime
  beginFrontBufferStroke()
  traceRecorder.input(
    "down", sampleTime, mappedPagePoint.x, mappedPagePoint.y,
    samplePressure, sampleTilt, sampleOrientation,
  )

  applyCommittedFrame(status)
  requestPredictionNow()
  if (!submitFrontBufferUpdate()) {
    cancelActiveStroke()
    return
  }
  invalidate()
}

private fun ViewerCanvas.moveStroke(event: MotionEvent) {
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

  val predictionWasVisible = stopPrediction()
  if (!prepareRealInputBatch(event, pointerIndex, terminal = false)) {
    if (predictionWasVisible && !submitFrontBufferUpdate()) cancelActiveStroke()
    return
  }
  val frame = try {
    inkEngine.mutateRealBatchAndRead(
      InkEngine.BATCH_OPERATION_UPDATE,
      realInputBatch,
    )
  } catch (_: InkStrokeMutationException) {
    cancelActiveStroke()
    return
  }
  recordRealBatch(frame, realInputBatch.count)
  require(frame.type == InkStrokeFrameCodec.COMMITTED_TYPE) {
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

private fun ViewerCanvas.endStroke(event: MotionEvent) {
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
  if (!prepareRealInputBatch(event, pointerIndex, terminal = true)) {
    cancelActiveStroke()
    return
  }
  val frame = try {
    inkEngine.mutateRealBatchAndRead(
      InkEngine.BATCH_OPERATION_END,
      realInputBatch,
    )
  } catch (_: InkStrokeMutationException) {
    cancelActiveStroke()
    return
  }
  recordRealBatch(frame, realInputBatch.count)
  require(frame.type == InkStrokeFrameCodec.FINAL_TYPE) {
    "Terminal stroke mutation did not return a final frame"
  }
  val shouldHandoff = presentationSequence > 0L
  val handoffGeneration = presentationGeneration
  val handoffSequence = presentationSequence
  var finalSnapshot: LowLatencyInkFinalSnapshot? = null
  if (frame.contours.isNotEmpty()) {
    val outline = StrokeOutline.copyOf(frame.contours).withColor(strokeColor())
    // Final geometry becomes durable presentation/history state before the
    // replaceable front-buffer composition is discarded below.
    core.commitInk(DocumentPageContext(documentState.generation, documentState.activePageId()), outline)
    if (shouldHandoff) {
      val pageToView = documentController.historyToViewTransform()
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
  activePointerId = ViewerCanvas.noPointer
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

private fun ViewerCanvas.prepareRealInputBatch(
  event: MotionEvent,
  pointerIndex: Int,
  terminal: Boolean,
): Boolean {
  if (event.historySize + 1 > RealInputBatch.MAX_INPUTS) {
    perfetto.marker("InkSign/real batch rejected: native bound exceeded")
    cancelActiveStroke()
    return false
  }
  realInputBatch.clear()
  for (historyPosition in 0 until event.historySize) {
    appendRealSample(event, pointerIndex, historyPosition, terminal = false)
  }
  val currentAccepted = appendRealSample(
    event, pointerIndex, InkMotionEventSamples.CURRENT_SAMPLE_POSITION, terminal,
  )
  if (terminal && !currentAccepted) return false
  return realInputBatch.count > 0
}

private fun ViewerCanvas.appendRealSample(
  event: MotionEvent,
  pointerIndex: Int,
  historyPosition: Int,
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
    val samplePressureValue = stylusSampleFrame.pressure(samplePressure)
    val sampleTiltValue = stylusSampleFrame.tilt(sampleTilt)
    val sampleOrientationValue = stylusSampleFrame.orientation(sampleOrientation)
    if (!samplePressureValue.isFinite() || !sampleTiltValue.isFinite() ||
      !sampleOrientationValue.isFinite()
    ) {
      return@withMotionSample false
    }
    realInputBatch.add(
      mappedPagePoint.x,
      mappedPagePoint.y,
      eventTime.toDouble(),
      samplePressureValue,
      sampleTiltValue,
      sampleOrientationValue,
    )
    traceRecorder.input(
      if (terminal && historyPosition == InkMotionEventSamples.CURRENT_SAMPLE_POSITION) {
        "up"
      } else {
        "move"
      },
      eventTime.toDouble() * ViewerCanvas.millisToSeconds,
      mappedPagePoint.x,
      mappedPagePoint.y,
      samplePressureValue,
      sampleTiltValue,
      sampleOrientationValue,
    )
    latestRealEventTimeMillis = eventTime
    true
  }
}

private fun ViewerCanvas.recordRealBatch(frame: InkStrokeFrame, sampleCount: Int) {
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

private fun ViewerCanvas.applyCommittedFrame(frame: InkStrokeFrame) {
  InkPerfetto.section("InkSign/apply frame") {
    frontBufferComposition.applyCommittedFrame(frame, presentationGeneration)
  }
}

private fun ViewerCanvas.ensureFrontBufferAvailableDuringGesture(): Boolean {
  if (activePointerId == ViewerCanvas.noPointer || lowLatencyInk.isAvailable) return true
  perfetto.marker("InkSign/front-buffer gesture cancelled: presenter unavailable")
  InkPerfetto.instantMarker("InkSign/front-buffer presenter lost during gesture")
  cancelActiveStroke()
  return false
}
