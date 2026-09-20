package com.margelo.nitro.inksignpdf

import android.view.MotionEvent

/** Converts Android motion samples into the normalized native-input values. */
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

  fun pressure(event: MotionEvent, pointerIndex: Int): Double {
    return normalizedPressure(
      event.getPressure(pointerIndex),
      event.getToolType(pointerIndex) == MotionEvent.TOOL_TYPE_STYLUS,
    )
  }

  fun altitude(event: MotionEvent, pointerIndex: Int): Double {
    return normalizedAltitude(
      event.getAxisValue(MotionEvent.AXIS_TILT, pointerIndex),
      event.getToolType(pointerIndex) == MotionEvent.TOOL_TYPE_STYLUS,
    )
  }

  fun orientation(event: MotionEvent, pointerIndex: Int): Double {
    return normalizedOrientation(
      event.getAxisValue(MotionEvent.AXIS_ORIENTATION, pointerIndex),
      event.getToolType(pointerIndex) == MotionEvent.TOOL_TYPE_STYLUS,
    )
  }

  fun normalizedPressure(value: Float, stylus: Boolean): Double {
    if (!stylus || !value.isFinite()) return -1.0
    return value.coerceIn(0.0f, 1.0f).toDouble()
  }

  fun normalizedAltitude(value: Float, stylus: Boolean): Double {
    if (!stylus || !value.isFinite()) return -1.0
    val tilt = value.coerceIn(0.0f, HALF_PI.toFloat()).toDouble()
    return HALF_PI - tilt
  }

  fun normalizedOrientation(value: Float, stylus: Boolean): Double {
    if (!stylus || !value.isFinite()) return -1.0
    return value.toDouble()
  }

  private const val HALF_PI = Math.PI / 2.0
}
