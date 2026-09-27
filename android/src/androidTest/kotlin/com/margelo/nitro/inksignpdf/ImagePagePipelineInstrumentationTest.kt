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
        assertTrue(session.horizontalSnapCandidates(0).isEmpty())
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

  @Test
  fun imageEncoderKeepsDefaultsAndAppliesPerCallResolutionAndQuality() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val detailed = File(context.cacheDir, "image-options-${UUID.randomUUID()}.jpg")
    val small = File(context.cacheDir, "image-small-${UUID.randomUUID()}.jpg")
    writePatternJpeg(detailed, 720, 360)
    writePatternJpeg(small, 20, 10)

    try {
      val page = PdfPageDimensions(144.0, 72.0)
      val defaultBytes = ImagePageEncoder.encode(detailed, page).imageBytes!!
      val defaultBitmap = decode(defaultBytes)
      try {
        assertEquals(400, defaultBitmap.width)
        assertEquals(200, defaultBitmap.height)
      } finally {
        defaultBitmap.recycle()
      }

      val lowDpiBytes = ImagePageEncoder.encode(detailed, page, targetDpi = 72.0).imageBytes!!
      val lowDpiBitmap = decode(lowDpiBytes)
      try {
        assertEquals(144, lowDpiBitmap.width)
        assertEquals(72, lowDpiBitmap.height)
      } finally {
        lowDpiBitmap.recycle()
      }

      val smallBytes = ImagePageEncoder.encode(small, page, targetDpi = 300.0).imageBytes!!
      val smallBitmap = decode(smallBytes)
      try {
        assertEquals(20, smallBitmap.width)
        assertEquals(10, smallBitmap.height)
      } finally {
        smallBitmap.recycle()
      }

      val qualityPage = PdfPageDimensions(184.32, 184.32)
      val lowQuality = ImagePageEncoder.encode(
        detailed,
        qualityPage,
        targetDpi = 200.0,
        jpegQuality = 0.0,
      ).imageBytes!!
      val highQuality = ImagePageEncoder.encode(
        detailed,
        qualityPage,
        targetDpi = 200.0,
        jpegQuality = 1.0,
      ).imageBytes!!
      assertTrue("Quality 1 should retain more image data", highQuality.size > lowQuality.size)
    } finally {
      detailed.delete()
      small.delete()
    }
  }

  private fun decode(bytes: ByteArray): Bitmap =
    android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
      ?: error("Image encoder produced an unreadable JPEG")

  private fun writePatternJpeg(file: File, width: Int, height: Int) {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    try {
      val pixels = IntArray(width * height) { index ->
        val x = index % width
        val y = index / width
        val value = (x * 17 + y * 31 + x * y) and 0xff
        Color.rgb(value, value, value)
      }
      bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
      FileOutputStream(file).use { output ->
        assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 100, output))
      }
    } finally {
      bitmap.recycle()
    }
  }

}
