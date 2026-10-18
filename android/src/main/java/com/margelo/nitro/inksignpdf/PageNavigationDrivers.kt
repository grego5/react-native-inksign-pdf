package com.margelo.nitro.inksignpdf

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator

internal interface PageNavigationPreviewScheduler {
  fun renderPreview(
    generation: Long,
    request: PdfTileRequest,
    completion: (Result<PdfTile>) -> Unit,
  )
}

internal interface PageNavigationSettlementDriver {
  interface Handle {
    fun cancel()
  }

  fun start(
    from: Float,
    to: Float,
    durationMillis: Long,
    onProgress: (Float) -> Unit,
    onEnd: () -> Unit,
  ): Handle
}

internal class ValueAnimatorPageNavigationSettlementDriver(
  private val requestAnimation: () -> Unit,
) : PageNavigationSettlementDriver {
  override fun start(
    from: Float,
    to: Float,
    durationMillis: Long,
    onProgress: (Float) -> Unit,
    onEnd: () -> Unit,
  ): PageNavigationSettlementDriver.Handle {
    val animator = ValueAnimator.ofFloat(from, to).apply {
      duration = durationMillis
      interpolator = android.view.animation.DecelerateInterpolator()
    }
    val handle = AnimatorHandle(animator)
    animator.addUpdateListener { value -> onProgress(value.animatedValue as Float) }
    animator.addListener(object : AnimatorListenerAdapter() {
      override fun onAnimationEnd(animation: Animator) {
        onEnd()
      }
    })
    animator.start()
    requestAnimation()
    return handle
  }

  private class AnimatorHandle(
    private val animator: ValueAnimator,
  ) : PageNavigationSettlementDriver.Handle {
    override fun cancel() {
      animator.removeAllUpdateListeners()
      animator.removeAllListeners()
      animator.cancel()
    }
  }
}
