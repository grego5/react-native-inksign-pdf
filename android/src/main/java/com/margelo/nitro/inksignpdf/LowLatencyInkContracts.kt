package com.margelo.nitro.inksignpdf

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.min

internal data class InkDirtyRegion(
  val left: Int,
  val top: Int,
  val right: Int,
  val bottom: Int,
) {
  init {
    require(left <= right && top <= bottom)
  }

  val isEmpty: Boolean
    get() = left >= right || top >= bottom

  fun union(other: InkDirtyRegion): InkDirtyRegion = InkDirtyRegion(
    minOf(left, other.left),
    minOf(top, other.top),
    maxOf(right, other.right),
    maxOf(bottom, other.bottom),
  )

  fun contains(other: InkDirtyRegion): Boolean =
    left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom

  fun pageBounds(transform: PageTransform): InkBounds {
    return InkBounds(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())
      .map(transform.inverse())
  }

  companion object {
    fun full(width: Int, height: Int): InkDirtyRegion {
      require(width >= 0 && height >= 0)
      return InkDirtyRegion(0, 0, width, height)
    }
  }
}

internal data class LowLatencyInkBoundsSnapshot(
  val liveTail: InkBounds?,
  val prediction: InkBounds?,
  val newlyStable: InkBounds?,
)

/** Inputs are page-space bounds before the immutable page-to-view transform is applied. */
internal object LowLatencyInkDirtyRegionCalculator {
  fun calculate(
    previous: LowLatencyInkBoundsSnapshot?,
    current: LowLatencyInkBoundsSnapshot,
    transform: PageTransform,
    viewWidth: Int,
    viewHeight: Int,
    reset: Boolean = false,
    outsetPx: Int = 1,
  ): InkDirtyRegion? {
    require(viewWidth >= 0 && viewHeight >= 0)
    require(outsetPx >= 0)
    if (reset) return InkDirtyRegion.full(viewWidth, viewHeight)

    var bounds: InkBounds? = null
    fun include(value: InkBounds?) {
      if (value == null) return
      bounds = bounds?.union(value) ?: value
    }
    previous?.let {
      include(it.liveTail)
      include(it.prediction)
    }
    include(current.liveTail)
    include(current.prediction)
    include(current.newlyStable)
    val mapped = bounds?.map(transform) ?: return null
    val left = floor(mapped.left.toDouble()).toInt() - outsetPx
    val top = floor(mapped.top.toDouble()).toInt() - outsetPx
    val right = ceil(mapped.right.toDouble()).toInt() + outsetPx
    val bottom = ceil(mapped.bottom.toDouble()).toInt() + outsetPx
    val clipped = InkDirtyRegion(
      left.coerceIn(0, viewWidth),
      top.coerceIn(0, viewHeight),
      right.coerceIn(0, viewWidth),
      bottom.coerceIn(0, viewHeight),
    )
    return clipped.takeUnless { it.isEmpty }
  }
}

internal enum class LowLatencyInkPathRole {
  REAL,
  PREDICTION,
}

internal data class LowLatencyInkDrawPath(
  val key: String,
  val data: InkPathData,
  val role: LowLatencyInkPathRole,
  val color: Int,
  val stable: Boolean = false,
  val stableContourStart: Long = -1L,
  val stableContourEnd: Long = -1L,
)

/** The only object retained by AndroidX between submission and callback/commit. */
internal data class LowLatencyInkRenderToken(
  val generation: Long,
  val sequence: Long,
) {
  init {
    require(generation >= 0L)
    require(sequence > 0L)
  }
}

/** Immutable page-space final presentation retained until the HWUI handoff completes. */
internal data class LowLatencyInkFinalSnapshot(
  val generation: Long,
  val sequence: Long,
  val paths: List<InkPathData>,
  val pageToView: PageTransform,
  val color: Int,
  val bufferWidth: Int,
  val bufferHeight: Int,
) {
  init {
    require(generation >= 0L)
    require(sequence > 0L)
    require(bufferWidth >= 0 && bufferHeight >= 0)
    require(paths.isNotEmpty())
  }
}

internal data class LowLatencyInkPresentationAcknowledgement(
  val generation: Long,
  val sequence: Long,
  val stableBoundary: Long,
)

internal data class LowLatencyInkDrawRequest(
  val generation: Long,
  val sequence: Long,
  val dirtyRegion: InkDirtyRegion,
  val pageToView: PageTransform,
  val bufferWidth: Int,
  val bufferHeight: Int,
  val paths: List<LowLatencyInkDrawPath>,
  val realPathCount: Int,
  val predictionPathCount: Int,
  val reset: Boolean = false,
  val eventAgeAtDeliveryMillis: Long = 0L,
  val dirtyRegionOutsetPx: Int = 1,
  val submitRequestedAtNanos: Long = 0L,
  val changedGeometryCount: Int = 0,
  val copiedGeometryCount: Int = 0,
  val stableBoundary: Long = 0L,
) {
  init {
    require(generation >= 0L)
    require(sequence > 0L)
    require(bufferWidth >= 0 && bufferHeight >= 0)
    require(paths.none { it.data.commands.isEmpty() })
    require(realPathCount >= 0 && predictionPathCount >= 0)
    require(realPathCount + predictionPathCount == paths.size)
  }
}

internal data class LowLatencyInkPayloadDiagnostics(
  val publishedPayloadCount: Long,
  val resolvedPayloadCount: Long,
  val missingPayloadCount: Long,
  val executingPayloadCount: Int,
  val pendingPayloadCount: Int,
  val peakPendingPayloadCount: Int,
  val supersededPayloadCount: Long,
)

internal data class LowLatencyInkDrawDiagnostics(
  val resetCount: Long = 0L,
  val staleRequestCount: Long = 0L,
  val copiedPathCount: Long = 0L,
  val pathRecordingCount: Long = 0L,
  val callbackCount: Long = 0L,
  val drawingCallbackCount: Long = 0L,
  val staleCallbackCount: Long = 0L,
  val cyanRealPathCount: Long = 0L,
  val magentaPredictionPathCount: Long = 0L,
  val renderedRegionCount: Long = 0L,
  val submitToCallbackStartDurationNanos: Long = 0L,
  val offscreenRecordingDurationNanos: Long = 0L,
  val replacementDurationNanos: Long = 0L,
  val finalMultiBufferSnapshotDrawCount: Long = 0L,
  val workerStableBitmapPresent: Boolean = false,
  val workerPathCacheCount: Int = 0,
  val workerOffscreenPresent: Boolean = false,
)

internal data class LowLatencyInkPresentationDiagnostics(
  val changedEventCount: Long,
  val incrementalRequestCount: Long,
  val fullResetCount: Long,
  val acceptedRequestCount: Long,
  val rejectedRequestCount: Long,
  val frontBufferOwnsActiveInk: Boolean,
  val eventCount: Long = 0L,
  val rawRealSampleCount: Long = 0L,
  val realBatchCount: Long = 0L,
  val realNativeMutationCount: Long = 0L,
  val realFrameCopyCount: Long = 0L,
  val realFrameDecodeCount: Long = 0L,
  val eventAgeAtDeliveryMillis: Long = 0L,
  val dirtyRegionAreaPixels: Long = 0L,
  val dirtyRegionOutsetPx: Int = 1,
  val changedGeometryCount: Long = 0L,
  val copiedGeometryCount: Long = 0L,
  val submitToCallbackStartDurationNanos: Long = 0L,
  val offscreenRecordingDurationNanos: Long = 0L,
  val frontBufferReplacementDurationNanos: Long = 0L,
  val handoffDurationNanos: Long = 0L,
  val cancelledCount: Long = 0L,
  val staleDroppedCount: Long = 0L,
  val retainedCommittedContourCount: Int = 0,
  val retainedPredictionContourCount: Int = 0,
  val stableBoundarySubmitted: Long = 0L,
  val stableBoundaryAcknowledged: Long = 0L,
  val lastCancellationReason: Int = 0,
)
