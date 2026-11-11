package com.margelo.nitro.inksignpdf

/** UI-thread-owned trace capture boundary. The real recorder exists only in debug variants. */
internal interface StrokeTraceRecorder {
  val isRecording: Boolean

  fun start()
  fun stop()
  fun input(
    event: String,
    timeSeconds: Double,
    x: Double,
    y: Double,
    pressure: Double,
    tilt: Double,
    orientation: Double,
  )
  fun penConfiguration(
    minWidth: Double,
    maxWidth: Double,
    smoothing: Double,
    logicalDisplayUnitsPerPageUnit: Double,
  )
  fun cancel()
  fun recordInputAgeAtDelivery(ageMillis: Long)
  fun medianInputAgeMillis(): Long
  fun p95InputAgeMillis(): Long
  fun setPresentationSummary(summary: StrokeTracePresentationSummary)
  fun snapshotForExport(): StrokeTraceSnapshot
}

/** Variant-specific frozen trace representation passed to the I/O exporter. */
internal interface StrokeTraceSnapshot

internal data class StrokeTracePresentationSummary(
  val eventCount: Long,
  val medianInputAgeMillis: Long,
  val p95InputAgeMillis: Long,
  val dirtyRegionAreaPixels: Long,
  val changedGeometryCount: Long,
  val copiedGeometryCount: Long,
  val submitToCallbackStartDurationNanos: Long,
  val offscreenRecordingDurationNanos: Long,
  val frontBufferReplacementDurationNanos: Long,
  val fullResetCount: Long,
  val staleDropCount: Long,
)
