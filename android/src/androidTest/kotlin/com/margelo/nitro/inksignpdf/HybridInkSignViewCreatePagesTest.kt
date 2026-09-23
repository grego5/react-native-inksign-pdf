package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.margelo.nitro.core.Promise
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HybridInkSignViewCreatePagesTest {
  @Test
  fun addPagesCreatesDocumentOnAnEmptyView() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val image = File.createTempFile("first-page-", ".jpg", context.cacheDir)
    image.writeBytes(testJpeg())
    val viewRef = AtomicReference<HybridInkSignView>()
    val promiseRef = AtomicReference<Promise<AddPagesResult>>()
    instrumentation.runOnMainSync {
      viewRef.set(HybridInkSignView(context))
      promiseRef.set(
        viewRef.get().addPages(
          AddPagesOptions(
            PageType.IMAGE,
            arrayOf(image.absolutePath),
            ImagePageSize(width = 595.28, height = 841.89),
          ),
        ),
      )
    }

    val completed = CountDownLatch(1)
    val result = AtomicReference<AddPagesResult>()
    val failure = AtomicReference<Throwable>()
    promiseRef.get()
      .then { result.set(it); completed.countDown() }
      .catch { failure.set(it); completed.countDown() }

    try {
      assertTrue("addPages did not settle", completed.await(10L, TimeUnit.SECONDS))
      failure.get()?.let { throw AssertionError("addPages rejected on an empty view", it) }
      val added = result.get()
      assertNotNull(added)
      assertEquals(1.0, added.addedPageCount, 0.0)
      assertNotNull(added.pageInfo)
      assertEquals(1.0, added.pageInfo!!.pageCount, 0.0)
      assertEquals(0.0, added.pageInfo!!.pageIndex, 0.0)
      assertEquals(595.28, added.pageInfo!!.width, 0.0001)
      assertEquals(841.89, added.pageInfo!!.height, 0.0001)
    } finally {
      instrumentation.runOnMainSync { viewRef.get().onDropView() }
      image.delete()
    }
  }

  private fun testJpeg(): ByteArray = ByteArrayOutputStream().use { output ->
    val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
    try {
      bitmap.eraseColor(android.graphics.Color.WHITE)
      check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output))
    } finally {
      bitmap.recycle()
    }
    output.toByteArray()
  }

  companion object {
    @JvmStatic
    @BeforeClass
    fun loadNativeLibrary() {
      NativeTestRuntime.initialize()
    }
  }
}
