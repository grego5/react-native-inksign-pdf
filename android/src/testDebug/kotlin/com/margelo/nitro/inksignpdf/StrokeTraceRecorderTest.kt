package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StrokeTraceRecorderTest {
  @Test
  fun recordsReplayOrderingWithRelativeTimeAndSanitizedOptionals() {
    val recorder = DebugStrokeTraceRecorder(capacity = 8)
    recorder.start()
    recorder.input("down", 10.0, 1.25, 2.5, Double.NaN, -1.0, Double.NaN)
    recorder.input("move", 10.25, 3.0, 4.0, 0.5, 0.25, 1.0)
    recorder.cancel()
    recorder.stop()

    assertEquals(
      listOf(
        "down,0.000000000,1.250000000,2.500000000,-1.000000000,-1.000000000,-1.000000000",
        "move,0.250000000,3.000000000,4.000000000,0.500000000,0.250000000,1.000000000",
        "cancel",
      ),
      recorder.snapshot(),
    )
    assertEquals(
      "event,time_seconds,page_x,page_y,pressure,tilt,orientation\n" +
        "down,0.000000000,1.250000000,2.500000000,-1.000000000,-1.000000000,-1.000000000\n" +
        "move,0.250000000,3.000000000,4.000000000,0.500000000,0.250000000,1.000000000\n" +
        "cancel\n",
      (recorder.snapshotForExport() as DebugStrokeTraceSnapshot).content(),
    )
  }

  @Test
  fun stopsAtTheConfiguredBound() {
    val recorder = DebugStrokeTraceRecorder(capacity = 2)
    recorder.start()
    recorder.input("down", 0.0, 0.0, 0.0, -1.0, -1.0, -1.0)
    recorder.cancel()

    assertFalse(recorder.isRecording)
    assertEquals(listOf(
      "down,0.000000000,0.000000000,0.000000000,-1.000000000,-1.000000000,-1.000000000",
      "cancel",
    ), recorder.snapshot())
  }

  @Test
  fun exportsDeterministicHeaderSummaryAndInputAges() {
    val recorder = DebugStrokeTraceRecorder(capacity = 8)
    recorder.start()
    recorder.recordInputAgeAtDelivery(7L)
    recorder.recordInputAgeAtDelivery(2L)
    recorder.recordInputAgeAtDelivery(9L)
    recorder.input("down", 10.0, 1.0, 2.0, -1.0, -1.0, -1.0)
    recorder.setPresentationSummary(
      StrokeTracePresentationSummary(
        eventCount = 3L,
        medianInputAgeMillis = recorder.medianInputAgeMillis(),
        p95InputAgeMillis = recorder.p95InputAgeMillis(),
        dirtyRegionAreaPixels = 42L,
        changedGeometryCount = 6L,
        copiedGeometryCount = 7L,
        submitToCallbackStartDurationNanos = 8L,
        offscreenRecordingDurationNanos = 9L,
        frontBufferReplacementDurationNanos = 10L,
        fullResetCount = 1L,
        staleDropCount = 0L,
      ),
    )
    recorder.stop()

    val content = (recorder.snapshotForExport() as DebugStrokeTraceSnapshot).content()
    assertTrue(content.startsWith(
      "event,time_seconds,page_x,page_y,pressure,tilt,orientation\n",
    ))
    assertTrue(content.contains(
      "# summary,front_buffer,3,7,9,42,6,7,8,9,10,1,0",
    ))
    assertEquals(7L, recorder.medianInputAgeMillis())
    assertEquals(9L, recorder.p95InputAgeMillis())
  }

  @Test
  fun exportsEffectivePenConfigurationBeforeItsDownRow() {
    val recorder = DebugStrokeTraceRecorder(capacity = 8)
    recorder.start()
    recorder.penConfiguration(0.125, 0.25, 0.35, 2.0)
    recorder.input("down", 10.0, 1.0, 2.0, -1.0, -1.0, -1.0)
    recorder.stop()

    val snapshot = recorder.snapshotForExport() as DebugStrokeTraceSnapshot
    assertEquals(
      listOf(
        "# pen,0.125000000,0.250000000,0.350000000,2.000000000",
        "down,0.000000000,1.000000000,2.000000000,-1.000000000,-1.000000000,-1.000000000",
      ),
      snapshot.rows(),
    )
    assertTrue(snapshot.content().contains("# pen,0.125000000,0.250000000,0.350000000,2.000000000\n"))
  }
}
