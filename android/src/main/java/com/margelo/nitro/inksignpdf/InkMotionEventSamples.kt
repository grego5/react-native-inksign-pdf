package com.margelo.nitro.inksignpdf

import android.view.InputDevice
import android.view.MotionEvent
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/** Reads Android motion samples for native input conversion. */
internal object InkMotionEventSamples {
  const val CURRENT_SAMPLE_POSITION = -1

  inline fun withMotionSample(
    event: MotionEvent,
    pointerIndex: Int,
    historyPosition: Int,
    block: (Float, Float, Long, Float, Float, Float) -> Boolean,
  ): Boolean {
    return if (historyPosition == CURRENT_SAMPLE_POSITION) {
      block(
        event.getX(pointerIndex),
        event.getY(pointerIndex),
        event.eventTime,
        event.getPressure(pointerIndex),
        event.getAxisValue(MotionEvent.AXIS_TILT, pointerIndex),
        event.getAxisValue(MotionEvent.AXIS_ORIENTATION, pointerIndex),
      )
    } else {
      block(
        event.getHistoricalX(pointerIndex, historyPosition),
        event.getHistoricalY(pointerIndex, historyPosition),
        event.getHistoricalEventTime(historyPosition),
        event.getHistoricalPressure(pointerIndex, historyPosition),
        event.getHistoricalAxisValue(
          MotionEvent.AXIS_TILT,
          pointerIndex,
          historyPosition,
        ),
        event.getHistoricalAxisValue(
          MotionEvent.AXIS_ORIENTATION,
          pointerIndex,
          historyPosition,
        ),
      )
    }
  }

  fun isSupportedTool(toolType: Int): Boolean {
    return toolType == MotionEvent.TOOL_TYPE_FINGER ||
      toolType == MotionEvent.TOOL_TYPE_STYLUS
  }
}

/**
 * Stylus metadata availability and the view-to-page direction frame frozen at
 * contact start. Values follow the engine contract: pressure in [0, 1], tilt
 * in [0, π/2] from the surface normal, orientation of the tip-to-end ray in
 * [0, 2π) from page +x toward page +y, and -1 when the stroke has no such axis.
 * An available axis with a non-finite sample yields NaN so the caller drops it.
 */
internal class InkStylusSampleFrame {
  var pressureAvailable = false
    private set
  var tiltAvailable = false
    private set
  var orientationAvailable = false
    private set
  private var viewToPageA = 1.0
  private var viewToPageB = 0.0
  private var viewToPageC = 0.0
  private var viewToPageD = 1.0

  fun begin(event: MotionEvent, pointerIndex: Int, viewToPage: PageTransform) {
    val stylus = event.getToolType(pointerIndex) == MotionEvent.TOOL_TYPE_STYLUS
    val device = event.device
    val orientationRange = device?.motionRange(MotionEvent.AXIS_ORIENTATION, event.source)
    begin(
      stylus = stylus,
      tiltSupported = device == null ||
        device.motionRange(MotionEvent.AXIS_TILT, event.source) != null,
      orientationSupported = device == null || (orientationRange != null &&
        isDirectionalOrientationRange(orientationRange.min, orientationRange.max)),
      viewToPage = viewToPage,
    )
  }

  fun begin(
    stylus: Boolean,
    tiltSupported: Boolean,
    orientationSupported: Boolean,
    viewToPage: PageTransform,
  ) {
    pressureAvailable = stylus
    tiltAvailable = stylus && tiltSupported
    orientationAvailable = stylus && orientationSupported
    viewToPageA = viewToPage.a
    viewToPageB = viewToPage.b
    viewToPageC = viewToPage.c
    viewToPageD = viewToPage.d
  }

  fun pressure(value: Float): Double {
    if (!pressureAvailable) return UNAVAILABLE
    if (!value.isFinite()) return Double.NaN
    return value.coerceIn(0.0f, 1.0f).toDouble()
  }

  fun tilt(value: Float): Double {
    if (!tiltAvailable) return UNAVAILABLE
    if (!value.isFinite()) return Double.NaN
    return value.toDouble().coerceIn(0.0, HALF_PI)
  }

  fun orientation(value: Float): Double {
    if (!orientationAvailable) return UNAVAILABLE
    if (!value.isFinite()) return Double.NaN
    // Android reports the tip direction clockwise from view up; the engine
    // takes the opposite tip-to-end ray in page coordinates.
    val angle = value.toDouble()
    val viewX = -sin(angle)
    val viewY = cos(angle)
    val pageX = viewToPageA * viewX + viewToPageC * viewY
    val pageY = viewToPageB * viewX + viewToPageD * viewY
    return normalizedRadians(atan2(pageY, pageX))
  }

  companion object {
    const val UNAVAILABLE = -1.0
    private const val HALF_PI = PI / 2.0
    private const val TWO_PI = PI * 2.0

    /** Directional devices span [-π, π]; axis-only devices span [-π/2, π/2]. */
    fun isDirectionalOrientationRange(min: Float, max: Float): Boolean =
      max - min > PI * 1.5

    /** Wraps an angle into [0, 2π) without changing its direction. */
    fun normalizedRadians(angle: Double): Double {
      val wrapped = angle % TWO_PI
      val positive = if (wrapped < 0.0) wrapped + TWO_PI else wrapped
      return if (positive >= TWO_PI) 0.0 else positive + 0.0
    }

    private fun InputDevice.motionRange(axis: Int, source: Int): InputDevice.MotionRange? =
      getMotionRange(axis, source) ?: getMotionRange(axis)
  }
}
