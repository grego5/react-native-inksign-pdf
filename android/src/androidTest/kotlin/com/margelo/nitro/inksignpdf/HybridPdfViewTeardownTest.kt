package com.margelo.nitro.inksignpdf

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HybridPdfViewTeardownTest {
  @Test
  fun repeatedDropRejectsNewOperationsAndRemainsIdempotent() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val rejected = AtomicInteger(0)
    val completed = CountDownLatch(dropCount * 2)

    instrumentation.runOnMainSync {
      repeat(dropCount) {
        val view = HybridPdfView(instrumentation.targetContext)
        val pendingOpen = view.open("dropped-view.pdf", null)
        view.onDropView()
        view.onDropView()
        pendingOpen.assertCancelled(rejected, completed)
        view.open("dropped-view.pdf", null).assertCancelled(rejected, completed)
      }
    }

    assertTrue(completed.await(5L, TimeUnit.SECONDS))
    assertEquals(dropCount * 2, rejected.get())
  }

  companion object {
    private const val dropCount = 20

    @JvmStatic
    @BeforeClass
    fun loadNativeLibrary() {
      NativeTestRuntime.initialize()
    }
  }
}

private fun com.margelo.nitro.core.Promise<PageInfo>.assertCancelled(
  rejected: AtomicInteger,
  completed: CountDownLatch,
) {
  catch {
    assertEquals("operation_cancelled", (it as PdfSessionException).code)
    rejected.incrementAndGet()
    completed.countDown()
  }
}
