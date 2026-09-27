package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.margelo.nitro.core.Promise
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
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
  fun mixedImportKeepsPdfPagesOutOfImageEncoding() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val image = File(context.cacheDir, "mixed-image-${UUID.randomUUID()}.jpg")
    val pdf = File(context.cacheDir, "mixed-pdf-${UUID.randomUUID()}.pdf")
    image.writeBytes(testJpeg())
    val seed = ImagePageEncoder.encode(image, PdfPageDimensions(80.0, 40.0))
    val seedPages = PdfiumPageAssembler.assemble(
      input = null,
      request = PdfiumAssemblyRequest(
        operation = PdfiumAssemblyOperation.CREATE,
        appendInputs = listOf(seed),
      ),
      scratch = pdf,
    )
    assertEquals(1, seedPages.size)

    val viewRef = AtomicReference<HybridInkSignView>()
    val promiseRef = AtomicReference<Promise<AddPagesResult>>()
    instrumentation.runOnMainSync {
      viewRef.set(HybridInkSignView(context))
      promiseRef.set(
        viewRef.get().addPages(
          AddPagesOptions(
            type = null,
            sources = arrayOf(pdf.absolutePath, image.absolutePath),
            imagePageSize = ImagePageSize(width = 144.0, height = 72.0),
            targetDpi = 72.0,
            jpegQuality = 0.1,
            activePage = null,
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
      assertTrue("mixed addPages did not settle", completed.await(10L, TimeUnit.SECONDS))
      failure.get()?.let { throw AssertionError("mixed addPages failed", it) }
      assertEquals(2.0, result.get().addedPageCount, 0.0)
      assertEquals(2.0, result.get().pageInfo!!.pageCount, 0.0)
      assertEquals(80.0, result.get().pageInfo!!.width, 0.0001)
      assertEquals(40.0, result.get().pageInfo!!.height, 0.0001)
    } finally {
      instrumentation.runOnMainSync { viewRef.get().onDropView() }
      image.delete()
      pdf.delete()
    }
  }

  @Test
  fun addPagesCreatesDocumentOnAnEmptyView() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val image = File.createTempFile("first-page-", ".jpg", context.cacheDir)
    val secondImage = File.createTempFile("second-page-", ".jpg", context.cacheDir)
    image.writeBytes(testJpeg())
    secondImage.writeBytes(testJpeg())
    val viewRef = AtomicReference<HybridInkSignView>()
    val promiseRef = AtomicReference<Promise<AddPagesResult>>()
    instrumentation.runOnMainSync {
      viewRef.set(HybridInkSignView(context))
      promiseRef.set(
        viewRef.get().addPages(
          AddPagesOptions(
            PageType.IMAGE,
            arrayOf(image.absolutePath, secondImage.absolutePath),
            ImagePageSize(width = 595.28, height = 841.89),
            null,
            null,
            AddPagesActivePage.CURRENT,
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
      assertEquals(2.0, added.addedPageCount, 0.0)
      assertNotNull(added.pageInfo)
      assertEquals(2.0, added.pageInfo!!.pageCount, 0.0)
      assertEquals(0.0, added.pageInfo!!.pageIndex, 0.0)
      assertEquals(595.28, added.pageInfo!!.width, 0.0001)
      assertEquals(841.89, added.pageInfo!!.height, 0.0001)
    } finally {
      instrumentation.runOnMainSync { viewRef.get().onDropView() }
      image.delete()
      secondImage.delete()
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
