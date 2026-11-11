package com.margelo.nitro.inksignpdf

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Reusable packed page-space inputs for one replaceable prediction batch. */
internal class PredictedInputBatch {
  internal val buffer: ByteBuffer = ByteBuffer.allocateDirect(
    MAX_INPUTS * DOUBLES_PER_INPUT * Double.SIZE_BYTES,
  ).order(ByteOrder.nativeOrder())
  internal var count: Int = 0
    private set

  internal fun clear() {
    count = 0
    buffer.clear()
  }

  internal fun add(
    x: Double,
    y: Double,
    timeMillis: Double,
    pressure: Double,
    tilt: Double,
    orientation: Double,
  ) {
    check(count < MAX_INPUTS) { "Predicted input batch is full" }
    buffer.putDouble(x)
    buffer.putDouble(y)
    buffer.putDouble(timeMillis)
    buffer.putDouble(pressure)
    buffer.putDouble(tilt)
    buffer.putDouble(orientation)
    count += 1
  }

  internal companion object {
    const val MAX_INPUTS = 64
    private const val DOUBLES_PER_INPUT = 6
  }
}
