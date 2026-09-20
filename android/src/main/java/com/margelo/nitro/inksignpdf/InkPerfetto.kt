package com.margelo.nitro.inksignpdf

import android.os.SystemClock
import android.os.Trace

/** Perfetto markers for the high-frequency ink path and its renderer worker callbacks. */
internal class InkPerfetto {
  private var nextEventSequence = 1L
  private var latestEventSequence = 0L

  fun eventReceived(eventTimeMillis: Long) {
    if (!Trace.isEnabled()) return
    val sequence = nextEventSequence
    nextEventSequence = if (sequence == Long.MAX_VALUE) 1L else sequence + 1L
    latestEventSequence = sequence
    Trace.setCounter("InkSign event sequence", sequence)
    Trace.setCounter("InkSign MotionEvent sample time ms", eventTimeMillis)
    Trace.setCounter(
      "InkSign event delivery age ms",
      (SystemClock.uptimeMillis() - eventTimeMillis).coerceAtLeast(0L),
    )
    marker("InkSign/event delivered")
  }

  fun sampleReceived(eventTimeMillis: Long) {
    if (!Trace.isEnabled()) return
    Trace.setCounter("InkSign event sequence", latestEventSequence)
    Trace.setCounter("InkSign latest real sample time ms", eventTimeMillis)
    val ageMillis = (SystemClock.uptimeMillis() - eventTimeMillis).coerceAtLeast(0L)
    Trace.setCounter("InkSign sample age ms", ageMillis)
    Trace.setCounter("InkSign latest real sample age ms", ageMillis)
  }

  fun marker(name: String) {
    if (!Trace.isEnabled()) return
    Trace.setCounter("InkSign event sequence", latestEventSequence)
    Trace.beginSection(name)
    Trace.endSection()
  }

  fun eventDelivered(eventTimeMillis: Long) {
    if (!Trace.isEnabled()) return
    Trace.setCounter(
      "InkSign event delivery age ms",
      (SystemClock.uptimeMillis() - eventTimeMillis).coerceAtLeast(0L),
    )
  }

  companion object {
    fun counter(name: String, value: Int) {
      counter(name, value.toLong())
    }

    fun counter(name: String, value: Long) {
      if (!Trace.isEnabled()) return
      Trace.setCounter(name, value)
    }

    fun instantMarker(name: String) {
      if (!Trace.isEnabled()) return
      Trace.beginSection(name)
      Trace.endSection()
    }

    fun nowNanos(): Long = SystemClock.elapsedRealtimeNanos()

    fun beginAsyncUpdate(sequence: Long) {
      if (!Trace.isEnabled()) return
      Trace.beginAsyncSection(frontBufferUpdateTrack, sequence.toInt())
    }

    fun endAsyncUpdate(sequence: Long) {
      if (!Trace.isEnabled()) return
      Trace.endAsyncSection(frontBufferUpdateTrack, sequence.toInt())
    }

    inline fun <T> section(name: String, block: () -> T): T {
      if (!Trace.isEnabled()) return block()
      Trace.beginSection(name)
      try {
        return block()
      } finally {
        Trace.endSection()
      }
    }

    private const val frontBufferUpdateTrack = "InkSign front-buffer update"
  }
}
