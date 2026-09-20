package com.margelo.nitro.inksignpdf

import java.io.File

/** Release implementation keeps generated Nitro methods but ships no CSV recorder. */
private class ReleaseStrokeTraceRecorder : StrokeTraceRecorder {
  override val isRecording: Boolean = false

  override fun start(): Nothing = error("Stroke trace recording is available only in debug builds")

  override fun stop(): Nothing = error("Stroke trace recording is available only in debug builds")

  override fun input(
    event: String,
    timeSeconds: Double,
    x: Double,
    y: Double,
    pressure: Double,
    tilt: Double,
    orientation: Double,
  ) = Unit

  override fun penConfiguration(
    minWidth: Double,
    maxWidth: Double,
    smoothing: Double,
    logicalDisplayUnitsPerPageUnit: Double,
  ) = Unit

  override fun cancel() = Unit

  override fun recordInputAgeAtDelivery(ageMillis: Long) = Unit

  override fun medianInputAgeMillis(): Long = 0L

  override fun p95InputAgeMillis(): Long = 0L

  override fun setPresentationSummary(summary: StrokeTracePresentationSummary) = Unit

  override fun snapshotForExport(): Nothing =
    error("Stroke trace recording is available only in debug builds")
}

internal fun createStrokeTraceRecorder(): StrokeTraceRecorder =
  ReleaseStrokeTraceRecorder()

internal fun exportStrokeTrace(
  output: File,
  snapshot: StrokeTraceSnapshot,
): File = error("Stroke trace recording is available only in debug builds")
