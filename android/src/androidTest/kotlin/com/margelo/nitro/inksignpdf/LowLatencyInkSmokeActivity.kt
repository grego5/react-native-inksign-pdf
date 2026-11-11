package com.margelo.nitro.inksignpdf

import android.app.Activity
import android.app.KeyguardManager
import android.os.Build
import android.os.Bundle
import android.view.SurfaceHolder
import android.widget.FrameLayout
import java.util.concurrent.CountDownLatch

internal class LowLatencyInkSmokeActivity : Activity() {
  lateinit var content: FrameLayout
  lateinit var presenter: LowLatencyInkPresenter
  val surfaceCreated = CountDownLatch(1)
  val surfaceDestroyed = CountDownLatch(1)
  val surfaceRecreated = CountDownLatch(1)
  val keyguardDismissalCompleted = CountDownLatch(1)
  @Volatile var surfaceCreatedCount = 0
    private set
  @Volatile var hasWindowFocus = false
    private set
  @Volatile var screenWakeConfigured = false
    private set
  @Volatile var keyguardDismissalSucceeded: Boolean? = null
    private set

  override fun onCreate(state: Bundle?) {
    super.onCreate(state)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      setShowWhenLocked(true)
      setTurnScreenOn(true)
      screenWakeConfigured = true
      requestKeyguardDismissalIfNeeded()
    }
    content = FrameLayout(this)
    setContentView(content)
    presenter = LowLatencyInkPresenter(this, mainView = content)
    presenter.view.holder.addCallback(object : SurfaceHolder.Callback {
      override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceCreatedCount += 1
        surfaceCreated.countDown()
        if (surfaceCreatedCount > 1) surfaceRecreated.countDown()
      }

      override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

      override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceDestroyed.countDown()
      }
    })
    content.addView(
      presenter.view,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
  }

  override fun onDestroy() {
    if (::presenter.isInitialized) presenter.release()
    super.onDestroy()
  }

  override fun onWindowFocusChanged(hasFocus: Boolean) {
    super.onWindowFocusChanged(hasFocus)
    hasWindowFocus = hasFocus
  }

  private fun requestKeyguardDismissalIfNeeded() {
    val keyguard = getSystemService(KeyguardManager::class.java)
    if (!keyguard.isKeyguardLocked) {
      keyguardDismissalSucceeded = true
      keyguardDismissalCompleted.countDown()
      return
    }
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
      override fun onDismissSucceeded() {
        keyguardDismissalSucceeded = true
        keyguardDismissalCompleted.countDown()
      }

      override fun onDismissCancelled() {
        keyguardDismissalSucceeded = false
        keyguardDismissalCompleted.countDown()
      }

      override fun onDismissError() {
        keyguardDismissalSucceeded = false
        keyguardDismissalCompleted.countDown()
      }
    })
  }
}
