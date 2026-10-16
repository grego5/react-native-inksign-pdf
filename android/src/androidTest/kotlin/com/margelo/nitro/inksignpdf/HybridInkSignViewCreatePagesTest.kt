package com.margelo.nitro.inksignpdf

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.margelo.nitro.core.Promise
import android.graphics.Bitmap
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

    val document = HybridInkSignDocument(context)

    try {
      await(instrumentation) {
        document.initializeSource(pdf.absolutePath)
      }
      val result = await(instrumentation) {
        document.addPages(DocumentAddPagesOptions(
          type = null,
          tag = null,
          sources = arrayOf(pdf.absolutePath, image.absolutePath),
          imagePageSize = ImagePageSize(width = 144.0, height = 72.0),
          targetDpi = 72.0,
          jpegQuality = 0.1,
        ))
      }
      assertEquals(2.0, result.addedPageCount, 0.0)
      assertEquals(3.0, result.pageCount, 0.0)
      val pdfPage = await(instrumentation) { document.getPage(PageQuery.create(1.0)) }
      val imagePage = await(instrumentation) { document.getPage(PageQuery.create(2.0)) }
      assertEquals(80.0, pdfPage.getState().width, 0.0001)
      assertEquals(40.0, pdfPage.getState().height, 0.0001)
      assertEquals(144.0, imagePage.getState().width, 0.0001)
      assertEquals(72.0, imagePage.getState().height, 0.0001)
    } finally {
      await(instrumentation) { document.close() }
      image.delete()
      pdf.delete()
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

  private fun <T> await(instrumentation: android.app.Instrumentation, request: () -> Promise<T>): T {
    val completed = CountDownLatch(1)
    val result = AtomicReference<T>()
    val failure = AtomicReference<Throwable>()
    instrumentation.runOnMainSync {
      request().then { result.set(it); completed.countDown() }
        .catch { failure.set(it); completed.countDown() }
    }
    assertTrue("Document command did not settle", completed.await(20L, TimeUnit.SECONDS))
    failure.get()?.let { throw AssertionError("Document command failed", it) }
    return checkNotNull(result.get())
  }

  companion object {
    @JvmStatic
    @BeforeClass
    fun loadNativeLibrary() {
      NativeTestRuntime.initialize()
    }
  }
}
