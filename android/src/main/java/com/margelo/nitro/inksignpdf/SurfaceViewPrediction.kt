package com.margelo.nitro.inksignpdf

import android.os.SystemClock
import android.view.MotionEvent
import kotlin.math.max

internal fun SurfaceView.requestPredictionNow(): SurfaceView.PredictionReplacementEffect {
  val previousBounds = previousFrontBufferBounds?.prediction
  if (activePointerId == SurfaceView.noPointer) {
    return SurfaceView.PredictionReplacementEffect(
      previousBounds,
      frontBufferComposition.frontBufferBounds().prediction,
    )
  }
  predictionRequestCount += 1L
  val startedAt = SystemClock.elapsedRealtimeNanos()
  val predictedEvent = motionEventPredictor.value.predict()
  val predictionStatus = try {
    predictedInputBatch.clear()
    if (predictedEvent == null) {
      PredictionBatchStatus.ABSENT
    } else {
      val pointerIndex = predictedEvent.findPointerIndex(activePointerId)
      if (predictedEvent.actionMasked == MotionEvent.ACTION_MOVE &&
        pointerIndex >= 0 &&
        predictedEvent.getToolType(pointerIndex) == activeToolType
      ) {
        predictedLastEventTimeMillis = latestRealEventTimeMillis?.toDouble()
          ?: predictedEvent.eventTime.toDouble()
        val stylus = activeToolType == MotionEvent.TOOL_TYPE_STYLUS
        var valid = true
        for (historyPosition in 0 until predictedEvent.historySize) {
          if (!appendPredictedSample(predictedEvent, pointerIndex, historyPosition, stylus)) {
            valid = false
            break
          }
        }
        if (valid) {
          appendPredictedSample(
            predictedEvent,
            pointerIndex,
            InkMotionEventSamples.CURRENT_SAMPLE_POSITION,
            stylus,
          )
          if (predictedInputBatch.count == 0) {
            PredictionBatchStatus.EMPTY
          } else {
            PredictionBatchStatus.VALID
          }
        } else {
          predictedInputBatch.clear()
          PredictionBatchStatus.INVALID
        }
      } else {
        PredictionBatchStatus.INVALID
      }
    }
  } finally {
    predictedEvent?.recycle()
  }
  val frame = PredictionReplacementPolicy.replaceIfUsable(
    predictionStatus,
    predictedInputBatch.count,
  ) {
    val currentTimeMillis = max(
      SystemClock.uptimeMillis().toDouble(),
      latestRealEventTimeMillis?.toDouble() ?: 0.0,
    )
    InkPerfetto.section("InkSign/platform prediction replacement") {
      strokeEngine.replacePredictedInputs(predictedInputBatch, currentTimeMillis)
    }.also {
      InkPerfetto.counter(
        "InkSign prediction replacement current time ms",
        currentTimeMillis.toLong(),
      )
      perfetto.marker("InkSign/platform prediction")
    }
  }
  if (frame == null) {
    predictionDurationNanos +=
      (SystemClock.elapsedRealtimeNanos() - startedAt).coerceAtLeast(0L)
    predictionSuppressedCount += 1L
    perfetto.marker("InkSign/prediction suppressed")
    reportPredictionCounters()
    return SurfaceView.PredictionReplacementEffect(
      previousBounds = previousBounds,
      currentBounds = frontBufferComposition.frontBufferBounds().prediction,
    )
  }
  if (frame.type == StrokeFrameCodec.PREDICTION_TYPE &&
    frame.diagnostics.suppressionReason == SurfaceView.PREDICTION_SUPPRESSION_NONE &&
    frame.contours.isNotEmpty()
  ) {
    predictionFrameCount += 1L
    frontBufferComposition.applyPredictionFrame(frame, presentationGeneration)
    perfetto.marker("InkSign/prediction installed")
  } else if (frame.type == StrokeFrameCodec.PREDICTION_TYPE) {
    predictionSuppressedCount += 1L
    frontBufferComposition.clearPrediction()
  }
  predictionDurationNanos +=
    (SystemClock.elapsedRealtimeNanos() - startedAt).coerceAtLeast(0L)
  reportPredictionDiagnostics(frame)
  reportPredictionCounters()
  return SurfaceView.PredictionReplacementEffect(
    previousBounds = previousBounds,
    currentBounds = frontBufferComposition.frontBufferBounds().prediction,
  )
}

private fun SurfaceView.reportPredictionCounters() {
  InkPerfetto.counter("InkSign prediction requests", predictionRequestCount)
  InkPerfetto.counter("InkSign prediction frames", predictionFrameCount)
  InkPerfetto.counter("InkSign prediction suppressed", predictionSuppressedCount)
  InkPerfetto.counter("InkSign prediction duration ns", predictionDurationNanos)
}

private fun SurfaceView.reportPredictionDiagnostics(frame: StrokeFrame) {
  val diagnostics = frame.diagnostics
  InkPerfetto.counter("InkSign queued real input count", diagnostics.queuedRealInputCount)
  InkPerfetto.counter("InkSign processed real input count", diagnostics.processedRealInputCount)
  InkPerfetto.counter("InkSign queued predicted input count", diagnostics.queuedPredictedInputCount)
  InkPerfetto.counter("InkSign processed predicted input count", diagnostics.processedPredictedInputCount)
  InkPerfetto.counter("InkSign stable modeled input count", diagnostics.stableModeledInputCount)
  InkPerfetto.counter("InkSign real modeled input count", diagnostics.realModeledInputCount)
  InkPerfetto.counter("InkSign full modeled input count", diagnostics.fullModeledInputCount)
  InkPerfetto.counter("InkSign real moving speed", diagnostics.realMovingSpeed.toLong())
  InkPerfetto.counter("InkSign real normalized speed x1000",
    (diagnostics.realNormalizedSpeed * 1000.0).toLong())
  InkPerfetto.counter("InkSign predicted normalized speed x1000",
    (diagnostics.predictedNormalizedSpeed * 1000.0).toLong())
  InkPerfetto.counter("InkSign prediction suppression reason",
    diagnostics.suppressionReason.toLong())
  InkPerfetto.counter("InkSign input age us",
    (diagnostics.inputAgeAtReplacement * 1_000_000.0).toLong())
  InkPerfetto.counter("InkSign platform lead us",
    (diagnostics.platformPredictionTemporalLead * 1_000_000.0).toLong())
  InkPerfetto.counter("InkSign modeled lead us",
    (diagnostics.modeledPredictionTemporalLead * 1_000_000.0).toLong())
  InkPerfetto.counter("InkSign platform longitudinal lead um",
    (diagnostics.platformPredictionLongitudinalLead * 1_000_000.0).toLong())
  InkPerfetto.counter("InkSign modeled longitudinal lead um",
    (diagnostics.modeledPredictionLongitudinalLead * 1_000_000.0).toLong())
  InkPerfetto.counter("InkSign platform lateral error um",
    (diagnostics.platformPredictionLateralError * 1_000_000.0).toLong())
  InkPerfetto.counter("InkSign modeled lateral error um",
    (diagnostics.modeledPredictionLateralError * 1_000_000.0).toLong())
  InkPerfetto.counter("InkSign C++ model duration ns", diagnostics.modelDurationNanos)
  InkPerfetto.counter("InkSign C++ geometry duration ns", diagnostics.geometryDurationNanos)
  InkPerfetto.counter("InkSign direction valid",
    if (diagnostics.validityFlags and (1 shl 7) != 0) 1L else 0L)
}

private fun SurfaceView.appendPredictedSample(
  event: MotionEvent,
  pointerIndex: Int,
  historyPosition: Int,
  stylus: Boolean,
): Boolean {
  return InkMotionEventSamples.withMotionSample(
    event, pointerIndex, historyPosition,
  ) {
      x, y, eventTime, samplePressure, sampleTilt, sampleOrientation ->
    if (eventTime.toDouble() <= predictedLastEventTimeMillis ||
      !documentController.mapPagePoint(x, y, mappedPagePoint)
    ) {
      return@withMotionSample false
    }
    val pressureValue = InkMotionEventSamples.normalizedPressure(samplePressure, stylus)
    val altitudeValue = InkMotionEventSamples.normalizedAltitude(sampleTilt, stylus)
    val orientationValue = InkMotionEventSamples.normalizedOrientation(sampleOrientation, stylus)
    if (!pressureValue.isFinite() || !altitudeValue.isFinite() ||
      !orientationValue.isFinite() ||
      predictedInputBatch.count >= PredictedInputBatch.MAX_INPUTS
    ) {
      return@withMotionSample false
    }
    predictedInputBatch.add(
      mappedPagePoint.x,
      mappedPagePoint.y,
      eventTime.toDouble(),
      pressureValue,
      altitudeValue,
      orientationValue,
    )
    predictedLastEventTimeMillis = eventTime.toDouble()
    true
  }
}

internal fun SurfaceView.stopPrediction(): Boolean {
  val wasVisible = frontBufferComposition.frontBufferBounds().prediction != null
  frontBufferComposition.clearPrediction()
  return wasVisible
}
