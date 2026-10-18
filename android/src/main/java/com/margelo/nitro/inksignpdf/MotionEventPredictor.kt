package com.margelo.nitro.inksignpdf

import android.view.MotionEvent
import android.view.View

/** Small seam around AndroidX so surface input tests can control prediction. */
internal interface InputPredictor {
  fun record(event: MotionEvent)

  fun predict(): MotionEvent?
}

internal class PlatformMotionEventPredictor(view: View) : InputPredictor {
  private val delegate = androidx.input.motionprediction.MotionEventPredictor.newInstance(view)

  override fun record(event: MotionEvent) {
    delegate.record(event)
  }

  override fun predict(): MotionEvent? = delegate.predict()
}
