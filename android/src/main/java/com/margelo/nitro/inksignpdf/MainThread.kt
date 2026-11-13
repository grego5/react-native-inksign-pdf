package com.margelo.nitro.inksignpdf

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CountDownLatch

internal fun <T> onMainThread(action: () -> T): T {
  if (Looper.myLooper() == Looper.getMainLooper()) return action()
  val latch = CountDownLatch(1)
  var result: Result<T>? = null
  if (!Handler(Looper.getMainLooper()).post { result = runCatching(action); latch.countDown() })
    throw PdfSessionException("operation_cancelled", "The owner executor is unavailable")
  try { latch.await() }
  catch (error: InterruptedException) {
    Thread.currentThread().interrupt()
    throw PdfSessionException("operation_cancelled", "Owner-executor dispatch was interrupted")
  }
  return checkNotNull(result).getOrThrow()
}
