package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ImagePagePipelineInstrumentationTest {
  @Before
  fun loadNativeModule() {
    NativeTestRuntime.initialize()
  }

  @Test
  fun imageOnlyPageRendersTheEncodedImage() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val image = File(context.cacheDir, "image-page-${UUID.randomUUID()}.jpg")
    val candidate = File(context.cacheDir, "image-page-${UUID.randomUUID()}.pdf")
    val bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888)
    try {
      bitmap.eraseColor(Color.RED)
      FileOutputStream(image).use { output ->
        assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, output))
      }
      val imageInput = ImagePageEncoder.encode(
        image,
        PdfPageDimensions(width = 160.0, height = 100.0),
      )
      val encodedBytes = imageInput.imageBytes!!
      val encoded = android.graphics.BitmapFactory.decodeByteArray(encodedBytes, 0, encodedBytes.size)
      try {
        val encodedCenter = encoded.getPixel(encoded.width / 2, encoded.height / 2)
        assertTrue(
          "The encoded JPEG should retain the red source; center=$encodedCenter",
          Color.red(encodedCenter) > 180 && Color.green(encodedCenter) < 100 && Color.blue(encodedCenter) < 100,
        )
      } finally {
        encoded.recycle()
      }
      val pages = PdfiumPageAssembler.assemble(
        input = null,
        request = PdfiumAssemblyRequest(
          operation = PdfiumAssemblyOperation.CREATE,
          appendInputs = listOf(imageInput),
        ),
        scratch = candidate,
      )
      assertEquals(1, pages.size)
      assertEquals(160.0, pages.single().width, 0.001)
      assertEquals(100.0, pages.single().height, 0.001)

      val session = PdfiumRenderSession.open(candidate.readBytes())
      try {
        val rendered = Bitmap.createBitmap(160, 100, Bitmap.Config.ARGB_8888)
        try {
          assertTrue(
            session.renderPageIntoBitmap(
              pageIndex = 0,
              bitmap = rendered,
              pageToDevice = PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
              clip = PdfiumRect(0.0, 0.0, 160.0, 100.0),
              flags = pdfiumAndroidDisplayFlags,
            ),
          )
          val pixels = IntArray(rendered.width * rendered.height)
          rendered.getPixels(pixels, 0, rendered.width, 0, 0, rendered.width, rendered.height)
          val redPixels = pixels.count { Color.red(it) > 180 && Color.green(it) < 100 && Color.blue(it) < 100 }
          assertTrue(
            "The saved image page should render the encoded red image; " +
              "redPixels=$redPixels",
            redPixels > 100,
          )
        } finally {
          rendered.recycle()
        }
      } finally {
        session.close()
      }
    } finally {
      bitmap.recycle()
      image.delete()
      candidate.delete()
    }
  }

}
