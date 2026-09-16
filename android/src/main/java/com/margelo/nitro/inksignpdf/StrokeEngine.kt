package com.margelo.nitro.inksignpdf

import androidx.annotation.Keep
import com.facebook.jni.HybridData
import com.facebook.proguard.annotations.DoNotStrip
import dalvik.annotation.optimization.FastNative
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Kotlin owner for the shared C++ stroke engine.
 *
 * Pen configuration returns the C ABI status. Active mutations use the fused
 * mutation/frame operation so the borrowed native frame is decoded before the
 * next mutation without a second JNI transition.
 */
@Keep
@DoNotStrip
@Suppress("KotlinJniMissingFunction")
internal class StrokeEngine {
  private val mHybridData: HybridData = initHybrid()
  private var closed = false
  private var frameBuffer = ByteBuffer.allocateDirect(INITIAL_FRAME_BYTES)
    .order(ByteOrder.nativeOrder())
  private val decodedFrame = StrokeFrame()

  @FastNative
  private external fun initHybrid(): HybridData

  @FastNative
  private external fun configurePenNative(
    minWidth: Double,
    maxWidth: Double,
    smoothing: Double,
    logicalDisplayUnitsPerPageUnit: Double,
  ): Int

  @FastNative
  private external fun cancelNative()

  @FastNative
  private external fun copyFrameNative(buffer: ByteBuffer): Int

  @FastNative
  private external fun closeNative()

  @FastNative
  private external fun mutateAndCopyNative(
    operation: Int,
    x: Double,
    y: Double,
    time: Double,
    pressure: Double,
    tilt: Double,
    orientation: Double,
    buffer: ByteBuffer,
  ): Int

  @FastNative
  private external fun mutateBatchAndCopyNative(
    operation: Int,
    inputBuffer: ByteBuffer,
    inputCount: Int,
    buffer: ByteBuffer,
  ): Int

  @FastNative
  private external fun replacePredictedInputsNative(
    inputBuffer: ByteBuffer,
    inputCount: Int,
    currentTime: Double,
    buffer: ByteBuffer,
  ): Int

  internal fun configurePen(
    minWidth: Double,
    maxWidth: Double,
    smoothing: Double,
    logicalDisplayUnitsPerPageUnit: Double,
  ): Int {
    checkOpen()
    return configurePenNative(
      minWidth, maxWidth, smoothing, logicalDisplayUnitsPerPageUnit,
    )
  }

  internal fun beginAndRead(
    x: Double,
    y: Double,
    time: Double,
    pressure: Double = -1.0,
    tilt: Double = -1.0,
    orientation: Double = -1.0,
  ): StrokeFrame = mutateAndRead(
    operation = OPERATION_BEGIN,
    x = x,
    y = y,
    time = time,
    pressure = pressure,
    tilt = tilt,
    orientation = orientation,
  )

  internal fun updateAndRead(
    x: Double,
    y: Double,
    time: Double,
    pressure: Double = -1.0,
    tilt: Double = -1.0,
    orientation: Double = -1.0,
  ): StrokeFrame = mutateAndRead(
    operation = OPERATION_UPDATE,
    x = x,
    y = y,
    time = time,
    pressure = pressure,
    tilt = tilt,
    orientation = orientation,
  )

  internal fun endAndRead(
    x: Double,
    y: Double,
    time: Double,
    pressure: Double = -1.0,
    tilt: Double = -1.0,
    orientation: Double = -1.0,
  ): StrokeFrame = mutateAndRead(
    operation = OPERATION_END,
    x = x,
    y = y,
    time = time,
    pressure = pressure,
    tilt = tilt,
    orientation = orientation,
  )

  internal fun mutateRealBatchAndRead(
    operation: Int,
    batch: RealInputBatch,
  ): StrokeFrame {
    checkOpen()
    require(batch.count in 1..RealInputBatch.MAX_INPUTS)
    return InkPerfetto.section("InkSign/JNI real batch mutate+frame") {
      batch.buffer.position(0)
      batch.buffer.limit(batch.count * REAL_INPUT_DOUBLES * Double.SIZE_BYTES)
      var resultFrame: StrokeFrame? = null
      var mutationPending = true
      while (resultFrame == null) {
        val result = if (mutationPending) {
          mutationPending = false
          mutateBatchAndCopyNative(
            operation,
            batch.buffer,
            batch.count,
            frameBuffer,
          )
        } else {
          copyFrameNative(frameBuffer)
        }
        when {
          result == COPY_SUCCESS -> {
            resultFrame = InkPerfetto.section("InkSign/frame decode") {
              StrokeFrameCodec.decode(frameBuffer, decodedFrame)
            }
          }
          result >= 0 -> {
            frameBuffer = ByteBuffer.allocateDirect(nextFrameBufferCapacity(result))
              .order(ByteOrder.nativeOrder())
          }
          result <= MUTATION_ERROR_BASE -> {
            throw StrokeMutationException(MUTATION_ERROR_BASE - result)
          }
          else -> throw StrokeEngineException(-result)
        }
      }
      resultFrame!!
    }
  }

  internal fun replacePredictedInputs(
    batch: PredictedInputBatch,
    currentTimeMillis: Double,
  ): StrokeFrame {
    checkOpen()
    require(batch.count in 0..PredictedInputBatch.MAX_INPUTS)
    return InkPerfetto.section("InkSign/JNI replace prediction") {
      batch.buffer.position(0)
      batch.buffer.limit(batch.count * PREDICTED_INPUT_DOUBLES * Double.SIZE_BYTES)
      var resultFrame: StrokeFrame? = null
      var mutationPending = true
      while (resultFrame == null) {
        val result = if (mutationPending) {
          mutationPending = false
          replacePredictedInputsNative(
            batch.buffer,
            batch.count,
            currentTimeMillis,
            frameBuffer,
          )
        } else {
          copyFrameNative(frameBuffer)
        }
        when {
          result == COPY_SUCCESS -> {
            resultFrame = InkPerfetto.section("InkSign/frame decode") {
              StrokeFrameCodec.decode(frameBuffer, decodedFrame)
            }
          }
          result >= 0 -> {
            frameBuffer = ByteBuffer.allocateDirect(nextFrameBufferCapacity(result))
              .order(ByteOrder.nativeOrder())
          }
          result <= MUTATION_ERROR_BASE -> {
            throw StrokePredictionException(MUTATION_ERROR_BASE - result)
          }
          else -> throw StrokeEngineException(-result)
        }
      }
      resultFrame!!
    }
  }

  internal fun cancel() {
    checkOpen()
    cancelNative()
  }

  internal fun close() {
    if (closed) return
    closed = true
    closeNative()
    mHybridData.resetNative()
  }

  private fun mutateAndRead(
    operation: Int,
    x: Double,
    y: Double,
    time: Double,
    pressure: Double,
    tilt: Double,
    orientation: Double,
  ): StrokeFrame {
    checkOpen()
    return InkPerfetto.section("InkSign/JNI mutate+frame") {
      var mutationPending = true
      var resultFrame: StrokeFrame? = null
      while (resultFrame == null) {
        val result = if (mutationPending) {
          mutationPending = false
          mutateAndCopyNative(
            operation,
            x,
            y,
            time,
            pressure,
            tilt,
            orientation,
            frameBuffer,
          )
        } else {
          copyFrameNative(frameBuffer)
        }
        when {
          result == COPY_SUCCESS -> {
            resultFrame = StrokeFrameCodec.decode(frameBuffer, decodedFrame)
          }
          result >= 0 -> {
            frameBuffer = ByteBuffer.allocateDirect(nextFrameBufferCapacity(result))
              .order(ByteOrder.nativeOrder())
          }
          result <= MUTATION_ERROR_BASE -> {
            throw StrokeMutationException(MUTATION_ERROR_BASE - result)
          }
          else -> throw StrokeEngineException(-result)
        }
      }
      resultFrame!!
    }
  }

  private fun checkOpen() {
    check(!closed) { "Stroke engine is closed" }
  }

  private fun nextFrameBufferCapacity(required: Int): Int {
    var capacity = frameBuffer.capacity().coerceAtLeast(1)
    while (capacity < required) {
      if (capacity > Int.MAX_VALUE / 2) return required
      capacity *= 2
    }
    return capacity
  }

  companion object {
    private const val INITIAL_FRAME_BYTES = 128
    private const val COPY_SUCCESS = 0
    private const val MUTATION_ERROR_BASE = -1000
    private const val OPERATION_BEGIN = 0
    private const val OPERATION_UPDATE = 1
    private const val OPERATION_END = 2
    private const val PREDICTED_INPUT_DOUBLES = 6
    private const val REAL_INPUT_DOUBLES = 6

    const val STATUS_OK = 0
    const val STATUS_NOT_IN_PROGRESS = 2
    const val BATCH_OPERATION_UPDATE = 1
    const val BATCH_OPERATION_END = 2
  }
}

internal class StrokeEngineException(
  val status: Int,
) : IllegalStateException("Stroke engine frame copy failed with status $status")

internal class StrokeMutationException(
  val status: Int,
) : IllegalStateException("Stroke engine mutation failed with status $status")

internal class StrokePredictionException(
  val status: Int,
) : IllegalStateException("Stroke engine prediction replacement failed with status $status")
