package com.margelo.nitro.inksignpdf

import kotlin.math.abs
import kotlin.math.min

internal enum class NavigationDirection { PREVIOUS, NEXT }

internal enum class SwipeDirection { LEFT, RIGHT }

internal enum class SwipePhase { CANDIDATE, DRAGGING, ARMED }

internal data class NavigationEligibility(
  val previous: Boolean,
  val next: Boolean,
)

internal data class NavigationGesture(
  val downX: Double,
  val downY: Double,
  val density: Double,
  val eligibility: NavigationEligibility,
  val isRtl: Boolean = false,
  val deadZonePx: Double = 8.0,
  val armDistancePx: Double = 72.0,
  val phase: SwipePhase = SwipePhase.CANDIDATE,
  val physicalDirection: SwipeDirection? = null,
  val targetDelta: Int? = null,
  val progress: Double = 0.0,
  val presentationOffsetPx: Double = 0.0,
  val presentationScale: Double = 1.0,
)

/** Pure down-time policy for one-step page navigation from a content edge. */
internal object PageNavigationPolicy {
  private const val DEAD_ZONE_DP = 8.0
  private const val ARM_FRACTION = 0.30
  private const val MAX_PRESENTATION_OFFSET_DP = 40.0
  private const val ARM_SCALE_START = 0.72
  private const val ARMED_PRESENTATION_SCALE = 0.96

  fun capture(
    downX: Double,
    downY: Double,
    density: Double,
    pageIndex: Int,
    pageCount: Int,
    pageWidth: Double,
    focusX: Double,
    visibleWidth: Double,
    zoom: Double,
    viewportWidthPx: Double = 400.0 * density,
    isRtl: Boolean = false,
  ): NavigationGesture? {
    if (!downX.isFinite() || !downY.isFinite() || !density.isFinite() || density <= 0.0 ||
      pageIndex !in 0 until pageCount || !pageWidth.isFinite() || pageWidth <= 0.0 ||
      !focusX.isFinite() || !visibleWidth.isFinite() || visibleWidth <= 0.0 ||
      !zoom.isFinite() || zoom <= 0.0 || !viewportWidthPx.isFinite() || viewportWidthPx <= 0.0
    ) return null

    val halfVisibleWidth = visibleWidth / 2.0
    val minimumFocus = if (visibleWidth >= pageWidth) pageWidth / 2.0 else halfVisibleWidth
    val maximumFocus = if (visibleWidth >= pageWidth) pageWidth / 2.0 else pageWidth - halfVisibleWidth
    val tolerance = 1.0 / (zoom * density)
    if (!minimumFocus.isFinite() || !maximumFocus.isFinite() || !tolerance.isFinite()) return null

    val atLeft = abs(focusX - minimumFocus) <= tolerance
    val atRight = abs(focusX - maximumFocus) <= tolerance
    val visiblePageWidthPx = min(pageWidth, visibleWidth) * zoom * density
    val armDistancePx = visiblePageWidthPx * ARM_FRACTION
    if (!visiblePageWidthPx.isFinite() || visiblePageWidthPx <= 0.0 ||
      !armDistancePx.isFinite() || armDistancePx <= DEAD_ZONE_DP * density
    ) return null
    return NavigationGesture(
      downX = downX,
      downY = downY,
      density = density,
      eligibility = NavigationEligibility(
        previous = pageIndex > 0 && (if (isRtl) atRight else atLeft),
        next = pageIndex + 1 < pageCount && (if (isRtl) atLeft else atRight)),
      isRtl = isRtl,
      deadZonePx = DEAD_ZONE_DP * density,
      armDistancePx = armDistancePx)
  }

  fun update(
    gesture: NavigationGesture,
    currentX: Double,
    currentY: Double,
  ): NavigationGesture {
    if (!currentX.isFinite() || !currentY.isFinite()) return gesture
    val deltaX = currentX - gesture.downX
    val deltaY = currentY - gesture.downY
    if (abs(deltaX) < gesture.deadZonePx || abs(deltaX) <= abs(deltaY)) {
      return gesture.copy(
        phase = SwipePhase.CANDIDATE,
        physicalDirection = null,
        targetDelta = null,
        progress = 0.0,
        presentationOffsetPx = 0.0,
        presentationScale = 1.0)
    }
    val physical = if (deltaX > 0.0) {
      SwipeDirection.RIGHT
    } else {
      SwipeDirection.LEFT
    }
    val direction = semanticDirection(gesture, physical) ?: return gesture.copy(
      phase = SwipePhase.CANDIDATE,
      physicalDirection = null,
      targetDelta = null,
      progress = 0.0,
      presentationOffsetPx = 0.0,
      presentationScale = 1.0)
    val denominator = (gesture.armDistancePx - gesture.deadZonePx).coerceAtLeast(1.0)
    val progress = ((abs(deltaX) - gesture.deadZonePx) / denominator).coerceIn(0.0, 1.0)
    val phase = if (progress >= 1.0) {
      SwipePhase.ARMED
    } else {
      SwipePhase.DRAGGING
    }
    val resisted = min(
      MAX_PRESENTATION_OFFSET_DP * gesture.density,
      (abs(deltaX) - gesture.deadZonePx).coerceAtLeast(0.0) *
        (MAX_PRESENTATION_OFFSET_DP * gesture.density) / denominator)
    val scaleProgress = ((progress - ARM_SCALE_START) /
      (1.0 - ARM_SCALE_START)).coerceIn(0.0, 1.0)
    val presentationScale = 1.0 -
      (1.0 - ARMED_PRESENTATION_SCALE) * scaleProgress
    return gesture.copy(
      phase = phase,
      physicalDirection = physical,
      targetDelta = if (direction == NavigationDirection.PREVIOUS) -1 else 1,
      progress = progress,
      presentationOffsetPx = if (physical == SwipeDirection.RIGHT) resisted else -resisted,
      presentationScale = presentationScale)
  }

  private fun semanticDirection(
    gesture: NavigationGesture,
    physical: SwipeDirection,
  ): NavigationDirection? {
    return when (physical) {
      SwipeDirection.RIGHT -> if (gesture.isRtl) {
        NavigationDirection.NEXT.takeIf { gesture.eligibility.next }
      } else {
        NavigationDirection.PREVIOUS.takeIf { gesture.eligibility.previous }
      }
      SwipeDirection.LEFT -> if (gesture.isRtl) {
        NavigationDirection.PREVIOUS.takeIf { gesture.eligibility.previous }
      } else {
        NavigationDirection.NEXT.takeIf { gesture.eligibility.next }
      }
    }
  }
}
