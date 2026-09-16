package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.view.SurfaceHolder
import android.view.View

/**
 * The transparent, non-interactive host for Android's front-buffer renderer.
 *
 * The z-order and holder format are configured before this view can create its
 * backing Surface. The regular [SurfaceView] remains the only input
 * receiver; this view deliberately returns false from [onTouchEvent].
 */
internal class LowLatencyInkView(
  context: Context,
  private val listener: Listener,
) : android.view.SurfaceView(context), SurfaceHolder.Callback {
  interface Listener {
    fun onOverlayAttached(view: LowLatencyInkView)
    fun onOverlayDetached(view: LowLatencyInkView)
    fun onOverlaySurfaceCreated(view: LowLatencyInkView)
    fun onOverlaySurfaceDestroyed(view: LowLatencyInkView)
    fun onOverlaySizeChanged(view: LowLatencyInkView, width: Int, height: Int)
  }

  init {
    // This is the configuration used by Google's V29 helper. It must precede
    // surface creation; child order alone does not establish SurfaceView z-order.
    setZOrderOnTop(true)
    holder.setFormat(PixelFormat.TRANSLUCENT)
    holder.addCallback(this)
    setBackgroundColor(Color.TRANSPARENT)
    isClickable = false
    isFocusable = false
    isFocusableInTouchMode = false
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    listener.onOverlayAttached(this)
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    listener.onOverlayDetached(this)
  }

  override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
    super.onSizeChanged(width, height, oldWidth, oldHeight)
    listener.onOverlaySizeChanged(this, width, height)
  }

  override fun surfaceCreated(holder: SurfaceHolder) {
    listener.onOverlaySurfaceCreated(this)
  }

  override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
    listener.onOverlaySizeChanged(this, width, height)
  }

  override fun surfaceDestroyed(holder: SurfaceHolder) {
    listener.onOverlaySurfaceDestroyed(this)
  }

  override fun onTouchEvent(event: android.view.MotionEvent): Boolean = false
}
