package com.margelo.nitro.inksignpdf

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.collections.AbstractMutableList

internal class StrokePredictionDiagnostics {
  var validityFlags: Int = 0
  var suppressionReason: Int = 0
  var queuedRealInputCount: Long = 0L
  var processedRealInputCount: Long = 0L
  var queuedPredictedInputCount: Long = 0L
  var processedPredictedInputCount: Long = 0L
  var stableModeledInputCount: Long = 0L
  var realModeledInputCount: Long = 0L
  var fullModeledInputCount: Long = 0L
  var realMovingSpeed: Double = 0.0
  var realNormalizedSpeed: Double = 0.0
  var predictedMovingSpeed: Double = 0.0
  var predictedNormalizedSpeed: Double = 0.0
  var latestRealRawInputX: Double = 0.0
  var latestRealRawInputY: Double = 0.0
  var latestPlatformPredictedRawInputX: Double = 0.0
  var latestPlatformPredictedRawInputY: Double = 0.0
  var stableModeledTipX: Double = 0.0
  var stableModeledTipY: Double = 0.0
  var realModeledTipX: Double = 0.0
  var realModeledTipY: Double = 0.0
  var predictedModeledEndpointX: Double = 0.0
  var predictedModeledEndpointY: Double = 0.0
  var terminalLeftEndpointX: Double = 0.0
  var terminalLeftEndpointY: Double = 0.0
  var terminalRightEndpointX: Double = 0.0
  var terminalRightEndpointY: Double = 0.0
  var renderedPredictionEndpointX: Double = 0.0
  var renderedPredictionEndpointY: Double = 0.0
  var latestRealRawTime: Double = 0.0
  var latestPlatformPredictedRawTime: Double = 0.0
  var stableModeledTime: Double = 0.0
  var realModeledTime: Double = 0.0
  var predictedModeledTime: Double = 0.0
  var renderedPredictionTime: Double = 0.0
  var realElapsedTime: Double = 0.0
  var fullElapsedTime: Double = 0.0
  var completeElapsedTime: Double = 0.0
  var inputAgeAtReplacement: Double = 0.0
  var platformPredictionTemporalLead: Double = 0.0
  var modeledPredictionTemporalLead: Double = 0.0
  var renderedPredictionTemporalLead: Double = 0.0
  var platformPredictionLongitudinalLead: Double = 0.0
  var modeledPredictionLongitudinalLead: Double = 0.0
  var renderedPredictionLongitudinalLead: Double = 0.0
  var platformPredictionLateralError: Double = 0.0
  var modeledPredictionLateralError: Double = 0.0
  var renderedPredictionLateralError: Double = 0.0
  var modelDurationNanos: Long = 0L
  var geometryDurationNanos: Long = 0L
  var rendererReplacementDurationNanos: Long = 0L
  var rendererDrawDurationNanos: Long = 0L

  internal fun readFrom(source: ByteBuffer) {
    validityFlags = source.int; suppressionReason = source.int
    queuedRealInputCount = source.long; processedRealInputCount = source.long
    queuedPredictedInputCount = source.long; processedPredictedInputCount = source.long
    stableModeledInputCount = source.long; realModeledInputCount = source.long
    fullModeledInputCount = source.long
    realMovingSpeed = source.double; realNormalizedSpeed = source.double
    predictedMovingSpeed = source.double; predictedNormalizedSpeed = source.double
    latestRealRawInputX = source.double; latestRealRawInputY = source.double
    latestPlatformPredictedRawInputX = source.double
    latestPlatformPredictedRawInputY = source.double
    stableModeledTipX = source.double; stableModeledTipY = source.double
    realModeledTipX = source.double; realModeledTipY = source.double
    predictedModeledEndpointX = source.double; predictedModeledEndpointY = source.double
    terminalLeftEndpointX = source.double; terminalLeftEndpointY = source.double
    terminalRightEndpointX = source.double; terminalRightEndpointY = source.double
    renderedPredictionEndpointX = source.double; renderedPredictionEndpointY = source.double
    latestRealRawTime = source.double; latestPlatformPredictedRawTime = source.double
    stableModeledTime = source.double; realModeledTime = source.double
    predictedModeledTime = source.double; renderedPredictionTime = source.double
    realElapsedTime = source.double; fullElapsedTime = source.double
    completeElapsedTime = source.double; inputAgeAtReplacement = source.double
    platformPredictionTemporalLead = source.double; modeledPredictionTemporalLead = source.double
    renderedPredictionTemporalLead = source.double
    platformPredictionLongitudinalLead = source.double; modeledPredictionLongitudinalLead = source.double
    renderedPredictionLongitudinalLead = source.double
    platformPredictionLateralError = source.double; modeledPredictionLateralError = source.double
    renderedPredictionLateralError = source.double
    modelDurationNanos = source.long; geometryDurationNanos = source.long
    rendererReplacementDurationNanos = source.long; rendererDrawDurationNanos = source.long
  }

  internal fun copyFrom(source: StrokePredictionDiagnostics) {
    validityFlags = source.validityFlags; suppressionReason = source.suppressionReason
    queuedRealInputCount = source.queuedRealInputCount
    processedRealInputCount = source.processedRealInputCount
    queuedPredictedInputCount = source.queuedPredictedInputCount
    processedPredictedInputCount = source.processedPredictedInputCount
    stableModeledInputCount = source.stableModeledInputCount
    realModeledInputCount = source.realModeledInputCount
    fullModeledInputCount = source.fullModeledInputCount
    realMovingSpeed = source.realMovingSpeed; realNormalizedSpeed = source.realNormalizedSpeed
    predictedMovingSpeed = source.predictedMovingSpeed
    predictedNormalizedSpeed = source.predictedNormalizedSpeed
    latestRealRawInputX = source.latestRealRawInputX; latestRealRawInputY = source.latestRealRawInputY
    latestPlatformPredictedRawInputX = source.latestPlatformPredictedRawInputX
    latestPlatformPredictedRawInputY = source.latestPlatformPredictedRawInputY
    stableModeledTipX = source.stableModeledTipX; stableModeledTipY = source.stableModeledTipY
    realModeledTipX = source.realModeledTipX; realModeledTipY = source.realModeledTipY
    predictedModeledEndpointX = source.predictedModeledEndpointX
    predictedModeledEndpointY = source.predictedModeledEndpointY
    terminalLeftEndpointX = source.terminalLeftEndpointX
    terminalLeftEndpointY = source.terminalLeftEndpointY
    terminalRightEndpointX = source.terminalRightEndpointX
    terminalRightEndpointY = source.terminalRightEndpointY
    renderedPredictionEndpointX = source.renderedPredictionEndpointX
    renderedPredictionEndpointY = source.renderedPredictionEndpointY
    latestRealRawTime = source.latestRealRawTime
    latestPlatformPredictedRawTime = source.latestPlatformPredictedRawTime
    stableModeledTime = source.stableModeledTime; realModeledTime = source.realModeledTime
    predictedModeledTime = source.predictedModeledTime
    renderedPredictionTime = source.renderedPredictionTime
    realElapsedTime = source.realElapsedTime; fullElapsedTime = source.fullElapsedTime
    completeElapsedTime = source.completeElapsedTime; inputAgeAtReplacement = source.inputAgeAtReplacement
    platformPredictionTemporalLead = source.platformPredictionTemporalLead
    modeledPredictionTemporalLead = source.modeledPredictionTemporalLead
    renderedPredictionTemporalLead = source.renderedPredictionTemporalLead
    platformPredictionLongitudinalLead = source.platformPredictionLongitudinalLead
    modeledPredictionLongitudinalLead = source.modeledPredictionLongitudinalLead
    renderedPredictionLongitudinalLead = source.renderedPredictionLongitudinalLead
    platformPredictionLateralError = source.platformPredictionLateralError
    modeledPredictionLateralError = source.modeledPredictionLateralError
    renderedPredictionLateralError = source.renderedPredictionLateralError
    modelDurationNanos = source.modelDurationNanos; geometryDurationNanos = source.geometryDurationNanos
    rendererReplacementDurationNanos = source.rendererReplacementDurationNanos
    rendererDrawDurationNanos = source.rendererDrawDurationNanos
  }
}

internal class StrokeCubicSegment {
  var p0X = 0f; var p0Y = 0f; var c1X = 0f; var c1Y = 0f
  var c2X = 0f; var c2Y = 0f; var p3X = 0f; var p3Y = 0f
  var sourceStart = 0L; var sourceEnd = 0L

  constructor()

  constructor(
    p0X: Float, p0Y: Float, c1X: Float, c1Y: Float,
    c2X: Float, c2Y: Float, p3X: Float, p3Y: Float,
    sourceStart: Long, sourceEnd: Long,
  ) {
    this.p0X = p0X; this.p0Y = p0Y; this.c1X = c1X; this.c1Y = c1Y
    this.c2X = c2X; this.c2Y = c2Y; this.p3X = p3X; this.p3Y = p3Y
    this.sourceStart = sourceStart; this.sourceEnd = sourceEnd
  }

  internal fun readFrom(source: ByteBuffer) {
    val nextP0X = source.double; val nextP0Y = source.double
    val nextC1X = source.double; val nextC1Y = source.double
    val nextC2X = source.double; val nextC2Y = source.double
    val nextP3X = source.double; val nextP3Y = source.double
    require(nextP0X.isFinite() && nextP0Y.isFinite() && nextC1X.isFinite() &&
      nextC1Y.isFinite() && nextC2X.isFinite() && nextC2Y.isFinite() &&
      nextP3X.isFinite() && nextP3Y.isFinite() &&
      nextP0X.toFloat().isFinite() && nextP0Y.toFloat().isFinite() &&
      nextC1X.toFloat().isFinite() && nextC1Y.toFloat().isFinite() &&
      nextC2X.toFloat().isFinite() && nextC2Y.toFloat().isFinite() &&
      nextP3X.toFloat().isFinite() && nextP3Y.toFloat().isFinite()) {
      "Stroke frame cubic coordinate is not finite"
    }
    val nextSourceStart = source.long
    val nextSourceEnd = source.long
    require(nextSourceStart >= 0L && nextSourceStart <= nextSourceEnd) {
      "Stroke frame segment source range is invalid"
    }
    p0X = nextP0X.toFloat(); p0Y = nextP0Y.toFloat()
    c1X = nextC1X.toFloat(); c1Y = nextC1Y.toFloat()
    c2X = nextC2X.toFloat(); c2Y = nextC2Y.toFloat()
    p3X = nextP3X.toFloat(); p3Y = nextP3Y.toFloat()
    sourceStart = nextSourceStart; sourceEnd = nextSourceEnd
  }
}

internal class StrokeContour {
  val segments = ReusableList<StrokeCubicSegment>()
  var sourceStart = 0L
  var sourceEnd = 0L
  var closed = false

  constructor(
    segments: List<StrokeCubicSegment>,
    sourceStart: Long, sourceEnd: Long, closed: Boolean,
  ) {
    this.segments.addAll(segments)
    this.sourceStart = sourceStart; this.sourceEnd = sourceEnd; this.closed = closed
  }

  constructor()
}

/** A small owner-local list with observable geometric capacity growth. */
internal class ReusableList<T> : AbstractMutableList<T>() {
  private var storage = arrayOfNulls<Any?>(0)
  override var size: Int = 0
    private set
  internal var capacityGrowthCount = 0L
    private set

  private fun ensureCapacity(required: Int) {
    if (required <= storage.size) return
    var next = storage.size.coerceAtLeast(1)
    while (next < required) {
      next = if (next >= Int.MAX_VALUE / 2) required else next * 2
    }
    storage = storage.copyOf(next)
    capacityGrowthCount++
  }

  @Suppress("UNCHECKED_CAST")
  override fun get(index: Int): T {
    if (index !in 0 until size) throw IndexOutOfBoundsException(index.toString())
    return storage[index] as T
  }

  override fun set(index: Int, element: T): T {
    val previous = get(index)
    storage[index] = element
    return previous
  }

  override fun add(index: Int, element: T) {
    if (index !in 0..size) throw IndexOutOfBoundsException(index.toString())
    ensureCapacity(size + 1)
    if (index < size) storage.copyInto(storage, index + 1, index, size)
    storage[index] = element
    size++
    modCount++
  }

  override fun removeAt(index: Int): T {
    val previous = get(index)
    if (index + 1 < size) storage.copyInto(storage, index, index + 1, size)
    storage[--size] = null
    modCount++
    return previous
  }

  override fun clear() {
    for (index in 0 until size) storage[index] = null
    size = 0
    modCount++
  }
}

internal class StrokeDecoderCounters {
  var segmentObjectCapacityGrowth = 0L
  var contourObjectCapacityGrowth = 0L
  var contourSegmentReferenceCapacityGrowth = 0L
}

internal class StrokeDecodeBank {
  val diagnostics = StrokePredictionDiagnostics()
  val segments = ReusableList<StrokeCubicSegment>()
  val contours = ReusableList<StrokeContour>()
}

internal class StrokeFrame {
  var type: Int = StrokeFrameCodec.COMMITTED_TYPE; private set
  var revision: Long = 0L; private set
  var committedPointCount: Long = 0L; private set
  val diagnostics = StrokePredictionDiagnostics()
  val contours = ReusableList<StrokeContour>()
  internal val decoderCounters = StrokeDecoderCounters()
  private val decodeBanks = arrayOf(StrokeDecodeBank(), StrokeDecodeBank())
  private var publishedBank = 0

  internal fun replace(
    type: Int, revision: Long, committedPointCount: Long,
    decodedContours: List<StrokeContour>,
  ) {
    this.type = type; this.revision = revision; this.committedPointCount = committedPointCount
    contours.clear(); contours.addAll(decodedContours)
  }

  internal fun replaceMetadata(
    type: Int, revision: Long, committedPointCount: Long,
  ) {
    this.type = type; this.revision = revision; this.committedPointCount = committedPointCount
  }

  internal fun writableDecodeBank(): StrokeDecodeBank = decodeBanks[1 - publishedBank]

  internal fun segmentScratchAt(
    bank: StrokeDecodeBank,
    index: Int,
  ): StrokeCubicSegment {
    if (index == bank.segments.size) {
      val growth = bank.segments.capacityGrowthCount
      bank.segments.add(StrokeCubicSegment())
      if (bank.segments.capacityGrowthCount > growth)
        decoderCounters.segmentObjectCapacityGrowth++
    }
    return bank.segments[index]
  }

  internal fun contourAt(bank: StrokeDecodeBank, index: Int): StrokeContour {
    if (index == bank.contours.size) {
      val growth = bank.contours.capacityGrowthCount
      bank.contours.add(StrokeContour())
      if (bank.contours.capacityGrowthCount > growth)
        decoderCounters.contourObjectCapacityGrowth++
    }
    return bank.contours[index]
  }

  internal fun publishDecoded(
    bank: StrokeDecodeBank,
    contourCount: Int,
    type: Int, revision: Long, committedPointCount: Long,
  ) {
    contours.clear()
    repeat(contourCount) { contours.add(bank.contours[it]) }
    diagnostics.copyFrom(bank.diagnostics)
    publishedBank = if (bank === decodeBanks[0]) 0 else 1
    replaceMetadata(type, revision, committedPointCount)
  }
}

/** Decodes the flattened native cubic segments and contour records. */
internal object StrokeFrameCodec {
  const val COMMITTED_TYPE = 0
  const val PREDICTION_TYPE = 1
  const val FINAL_TYPE = 2
  private const val MAGIC = 0x4E534546
  internal const val VERSION = 15
  internal const val HEADER_BYTES = 456
  private const val SEGMENT_BYTES = 80
  private const val CONTOUR_RECORD_BYTES = 40

  fun decode(source: ByteBuffer, target: StrokeFrame = StrokeFrame()): StrokeFrame {
    val buffer = source.order(ByteOrder.nativeOrder())
    buffer.clear()
    require(buffer.remaining() >= HEADER_BYTES) { "Stroke frame header is truncated" }
    require(buffer.int == MAGIC) { "Stroke frame magic is invalid" }
    require(buffer.int == VERSION) { "Stroke frame version is unsupported" }
    val type = buffer.int
    require(type in COMMITTED_TYPE..FINAL_TYPE) { "Stroke frame type is invalid" }
    buffer.int
    val revision = buffer.long
    val committedPointCount = buffer.long
    val segmentCount = buffer.long.toCount("cubic segment")
    val contourCount = buffer.long.toCount("contour")
    val decodeBank = target.writableDecodeBank()
    val diagnostics = decodeBank.diagnostics
    diagnostics.readFrom(buffer)
    val payloadBytes = Math.addExact(
      Math.multiplyExact(segmentCount, SEGMENT_BYTES),
      Math.multiplyExact(contourCount, CONTOUR_RECORD_BYTES),
    )
    require(buffer.remaining() >= payloadBytes) { "Stroke frame payload is truncated" }
    repeat(segmentCount) { target.segmentScratchAt(decodeBank, it).readFrom(buffer) }
    var segmentOffset = 0
    repeat(contourCount) {
      val start = buffer.long.toCount("contour segment start")
      val count = buffer.long.toCount("contour segment count")
      val sourceStart = buffer.long
      val sourceEnd = buffer.long
      val closed = buffer.int
      buffer.int
      require(start == segmentOffset) { "Stroke frame contour offsets are not ordered" }
      require(count > 0 && Math.addExact(start, count) <= segmentCount) {
        "Stroke frame contour segment range is invalid"
      }
      require(sourceStart >= 0L && sourceStart <= sourceEnd) {
        "Stroke frame contour source range is invalid"
      }
      require(closed == 1) { "Stroke frame contour is not closed" }
      val contour = target.contourAt(decodeBank, it)
      val referenceGrowth = contour.segments.capacityGrowthCount
      contour.segments.clear()
      repeat(count) { offset ->
        contour.segments += target.segmentScratchAt(decodeBank, start + offset)
      }
      if (contour.segments.capacityGrowthCount > referenceGrowth)
        target.decoderCounters.contourSegmentReferenceCapacityGrowth++
      contour.sourceStart = sourceStart; contour.sourceEnd = sourceEnd; contour.closed = true
      segmentOffset += count
    }
    require(segmentOffset == segmentCount) { "Stroke frame has unowned cubic segments" }
    target.publishDecoded(decodeBank, contourCount, type, revision,
      committedPointCount)
    return target
  }

  private fun Long.toCount(label: String): Int {
    require(this in 0L..Int.MAX_VALUE.toLong()) { "Stroke frame $label count is invalid" }
    return toInt()
  }

}
