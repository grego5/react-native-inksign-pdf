package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ImagePagePipelineInstrumentationTest {
  // Odd-width ramp, filters 0...4, split IDAT chunks, optionally transparent sample 7.
  private val gray4 = "iVBORw0KGgoAAAANSUhEUgAAABEAAAAFBAAAAABDsbWqAAAAA0lEQVR4nGOqZ4K+AAAACElEQVRgVHZN71x99rHUlJQAAAAZSURBVP0HRkYlCGBkYoABZkZBCGBkgYsBAPRdBiSN/jLkAAAAAElFTkSuQmCC"
  private val transparentGray4 = "iVBORw0KGgoAAAANSUhEUgAAABEAAAAFBAAAAABDsbWqAAAAAnRSTlMAB+j3WJsAAAADSURBVHicY6pngr4AAAAISURBVGBUdk3vXH32sdSUlAAAABlJREFU/QdGRiUIYGRigAFmRkEIYGSBiwEA9F0GJI3+MuQAAAAASUVORK5CYII="

  @Before
  fun loadNativeModule() {
    NativeTestRuntime.initialize()
  }

  @Test
  fun grayscalePngKeepsFourBitCompressedSamplesAndRendersAllFilters() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    for ((fixture, transparent) in listOf(gray4 to false, transparentGray4 to true)) {
      val image = File(context.cacheDir, "gray4-${UUID.randomUUID()}.png")
      val candidate = File(context.cacheDir, "gray4-${UUID.randomUUID()}.pdf")
      val exported = File(context.cacheDir, "gray4-export-${UUID.randomUUID()}.pdf")
      val original = android.util.Base64.decode(fixture, android.util.Base64.DEFAULT)
      try {
        image.writeBytes(original)
        val input = ImagePageEncoder.encode(image, PdfPageDimensions(170.0, 100.0))
        assertArrayEquals(original, input.imageBytes)
        assertEquals(PdfiumImagePlacement(a = 170.0, d = 50.0, f = 25.0), input.placement)
        PdfiumPageAssembler.assemble(null,
          PdfiumAssemblyRequest(PdfiumAssemblyOperation.CREATE, listOf(input)), candidate)
        val snapshot = PdfExportSnapshot(candidate.path, exported.path,
          listOf(PdfPageExportSnapshot(0, PdfPageDimensions(170.0, 100.0), emptyList())), 1L)
        PdfiumExporter.export(snapshot, PdfiumTextSnapshot(emptyList(), emptyList()), exported)
        val pdf = exported.readBytes()
        val dictionary = pdf.toString(Charsets.ISO_8859_1)
        assertTrue(Regex("/BitsPerComponent\\s+4\\b").containsMatchIn(dictionary))
        assertTrue(dictionary.contains("/DeviceGray"))
        val compressed = android.util.Base64.decode("eJxjYFR2Te9cffb9B0ZGJQhgZGKAAWZGQQhgZIGLAQD0XQYk", android.util.Base64.DEFAULT)
        assertTrue("PDF retains the original IDAT stream", dictionary.contains(compressed.toString(Charsets.ISO_8859_1)))
        val session = PdfiumRenderSession.open(pdf)
        val rendered = Bitmap.createBitmap(170, 100, Bitmap.Config.ARGB_8888)
        try {
          assertTrue(session.renderPageIntoBitmap(0, rendered,
            PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
            PdfiumRect(0.0, 0.0, 170.0, 100.0), flags = pdfiumAndroidDisplayFlags))
          assertTrue(Color.red(rendered.getPixel(85, 10)) > 240)
          for (y in 30..70 step 10) {
            assertTrue(Color.red(rendered.getPixel(5, y)) < 20)
            assertTrue(Color.red(rendered.getPixel(155, y)) > 235)
            assertTrue(abs((if (transparent) 255 else 119) - Color.red(rendered.getPixel(75, y))) <= 20)
          }
        } finally {
          rendered.recycle()
          session.close()
        }
        assertArrayEquals(original, image.readBytes())
      } finally {
        image.delete()
        candidate.delete()
        exported.delete()
      }
    }
  }

  @Test
  fun dpiPreservesSuitablePngAndQualityExplicitlyConvertsToJpeg() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val image = File(context.cacheDir, "gray4-override-${UUID.randomUUID()}.png")
    try {
      image.writeBytes(android.util.Base64.decode(gray4, android.util.Base64.DEFAULT))
      val page = PdfPageDimensions(170.0, 100.0)
      val preserved = ImagePageEncoder.encode(image, page, targetDpi = 72.0)
      assertArrayEquals(image.readBytes(), preserved.imageBytes)
      assertEquals(PdfiumImagePlacement(a = 170.0, d = 50.0, f = 25.0), preserved.placement)
      val converted = ImagePageEncoder.encode(image, page, jpegQuality = 0.8)
      assertArrayEquals(byteArrayOf(255.toByte(), 216.toByte()), converted.imageBytes!!.copyOfRange(0, 2))
      assertEquals(PdfiumImagePlacement(a = 170.0, d = 100.0), converted.placement)
    } finally {
      image.delete()
    }
  }

  @Test
  fun downsampledPngStaysFourBitGrayscaleAndExports() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val image = File(context.cacheDir, "gray4-resize-${UUID.randomUUID()}.png")
    val candidate = File(context.cacheDir, "gray4-resize-${UUID.randomUUID()}.pdf")
    try {
      image.writeBytes(android.util.Base64.decode(gray4, android.util.Base64.DEFAULT))
      val input = ImagePageEncoder.encode(image, PdfPageDimensions(170.0, 100.0), targetDpi = 3.6)
      val bytes = input.imageBytes!!
      assertEquals(4, bytes[24].toInt())
      assertEquals(0, bytes[25].toInt())
      val decoded = decode(bytes)
      try {
        assertEquals(9, decoded.width)
        assertEquals(5, decoded.height)
        assertTrue(Color.red(decoded.getPixel(0, 2)) < 40)
        assertTrue(Color.red(decoded.getPixel(8, 2)) > 230)
      } finally {
        decoded.recycle()
      }
      PdfiumPageAssembler.assemble(null,
        PdfiumAssemblyRequest(PdfiumAssemblyOperation.CREATE, listOf(input)), candidate)
      assertTrue(candidate.readText(Charsets.ISO_8859_1).contains("/DeviceGray"))
    } finally {
      image.delete()
      candidate.delete()
    }
  }

  @Test
  fun preservedJpegKeepsBytesAndDisplaysEveryExifOrientation() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val image = File(context.cacheDir, "jpeg-orientation-${UUID.randomUUID()}.jpg")
    val candidate = File(context.cacheDir, "jpeg-orientation-${UUID.randomUUID()}.pdf")
    val colors = listOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW)
    val expected = listOf(listOf(0, 1, 2, 3), listOf(1, 0, 3, 2), listOf(3, 2, 1, 0), listOf(2, 3, 0, 1),
      listOf(0, 2, 1, 3), listOf(2, 0, 3, 1), listOf(3, 1, 2, 0), listOf(1, 3, 0, 2))
    val bitmap = Bitmap.createBitmap(80, 40, Bitmap.Config.ARGB_8888)
    try {
      val canvas = Canvas(bitmap)
      val paint = Paint()
      for (corner in 0..3) {
        paint.color = colors[corner]
        val left = if (corner % 2 == 0) 0f else 40f
        val top = if (corner < 2) 0f else 20f
        canvas.drawRect(left, top, left + 40f, top + 20f, paint)
      }
      for (orientation in 1..8) {
        image.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it)) }
        ExifInterface(image.absolutePath).apply {
          setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
          saveAttributes()
        }
        val bytes = image.readBytes()
        val input = ImagePageEncoder.encode(image, PdfPageDimensions(100.0, 100.0), targetDpi = 200.0)
        assertArrayEquals(bytes, input.imageBytes)
        PdfiumPageAssembler.assemble(null,
          PdfiumAssemblyRequest(PdfiumAssemblyOperation.CREATE, listOf(input)), candidate)
        val pdf = candidate.readBytes()
        assertTrue("PDF preserves JPEG stream for EXIF $orientation",
          pdf.toString(Charsets.ISO_8859_1).contains(bytes.toString(Charsets.ISO_8859_1)))
        val session = PdfiumRenderSession.open(pdf)
        val rendered = Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888)
        try {
          assertTrue(session.renderPageIntoBitmap(0, rendered,
            PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
            PdfiumRect(0.0, 0.0, 100.0, 100.0), flags = pdfiumAndroidDisplayFlags))
          for (corner in 0..3) {
            val x = if (orientation <= 4) (if (corner % 2 == 0) 25 else 75) else (if (corner % 2 == 0) 37 else 62)
            val y = if (orientation <= 4) (if (corner < 2) 37 else 62) else (if (corner < 2) 25 else 75)
            val actual = rendered.getPixel(x, y)
            val color = colors[expected[orientation - 1][corner]]
            assertTrue("EXIF $orientation corner $corner",
              abs(Color.red(actual) - Color.red(color)) < 40 &&
                abs(Color.green(actual) - Color.green(color)) < 40 && abs(Color.blue(actual) - Color.blue(color)) < 40)
          }
        } finally {
          rendered.recycle()
          session.close()
        }
      }
    } finally {
      bitmap.recycle()
      image.delete()
      candidate.delete()
    }
  }

  @Test
  fun malformedPreservedPngDoesNotPublishPdf() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val candidate = File(context.cacheDir, "gray4-invalid-${UUID.randomUUID()}.pdf")
    val bytes = android.util.Base64.decode(gray4, android.util.Base64.DEFAULT)
    bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
    try {
      assertThrows(PdfSessionException::class.java) {
        PdfiumPageAssembler.assemble(null,
          PdfiumAssemblyRequest(PdfiumAssemblyOperation.CREATE, listOf(PdfiumAppendRequest(
            PageType.IMAGE, imageBytes = bytes, pageWidth = 170.0, pageHeight = 100.0,
            placement = PdfiumImagePlacement(a = 170.0, d = 50.0)))), candidate)
      }
      assertFalse(candidate.exists())
    } finally {
      candidate.delete()
    }
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
  fun highDpiA4RasterPreservesPageAspectAndContainsTheWholeImage() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val image = File(context.cacheDir, "image-a4-limit-${UUID.randomUUID()}.jpg")
    val candidate = File(context.cacheDir, "image-a4-limit-${UUID.randomUUID()}.pdf")
    val page = PdfPageDimensions(width = 595.2756, height = 841.8898)

    try {
      writeA4LimitPatternJpeg(image)
      val imageInput = ImagePageEncoder.encode(image, page, targetDpi = 2400.0)
      val encoded = decode(imageInput.imageBytes!!)
      try {
        assertEquals(8192, encoded.height)
        val expectedWidth = encoded.height * page.width / page.height
        assertTrue(
          "Raster dimensions should retain the A4 aspect ratio within one pixel; " +
            "encoded=${encoded.width}x${encoded.height}, expected width=$expectedWidth",
          abs(encoded.width - expectedWidth) <= 1.0,
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
      assertEquals(page.width, pages.single().width, 0.001)
      assertEquals(page.height, pages.single().height, 0.001)

      val session = PdfiumRenderSession.open(candidate.readBytes())
      try {
        val rendered = Bitmap.createBitmap(596, 842, Bitmap.Config.ARGB_8888)
        try {
          val scale = rendered.height / page.height
          assertTrue(
            session.renderPageIntoBitmap(
              pageIndex = 0,
              bitmap = rendered,
              pageToDevice = PdfiumAffineMatrix(scale, 0.0, 0.0, scale, 0.0, 0.0),
              clip = PdfiumRect(0.0, 0.0, page.width, page.height),
              flags = pdfiumAndroidDisplayFlags,
            ),
          )

          val pixels = IntArray(rendered.width * rendered.height)
          rendered.getPixels(pixels, 0, rendered.width, 0, 0, rendered.width, rendered.height)
          val centerY = rendered.height / 2
          assertTrue(
            "The left edge of the source image should remain visible",
            isRed(pixels[centerY * rendered.width + 20]),
          )
          assertTrue(
            "The right edge of the source image should remain visible",
            isBlue(pixels[centerY * rendered.width + 575]),
          )
          assertTrue(
            "The image should remain letterboxed on the page",
            isWhite(pixels[100 * rendered.width + 100]),
          )
          assertTrue(
            "The image should remain letterboxed on the page",
            isWhite(pixels[740 * rendered.width + 100]),
          )

          var minGreenX = rendered.width
          var minGreenY = rendered.height
          var maxGreenX = -1
          var maxGreenY = -1
          var hasYellowTopEdge = false
          var hasCyanBottomEdge = false
          pixels.forEachIndexed { index, pixel ->
            hasYellowTopEdge = hasYellowTopEdge || isYellow(pixel)
            hasCyanBottomEdge = hasCyanBottomEdge || isCyan(pixel)
            if (isGreen(pixel)) {
              val x = index % rendered.width
              val y = index / rendered.width
              minGreenX = minOf(minGreenX, x)
              minGreenY = minOf(minGreenY, y)
              maxGreenX = maxOf(maxGreenX, x)
              maxGreenY = maxOf(maxGreenY, y)
            }
          }
          assertTrue("The top edge of the source image should remain visible", hasYellowTopEdge)
          assertTrue("The bottom edge of the source image should remain visible", hasCyanBottomEdge)
          assertTrue("The square source marker should render", maxGreenX >= minGreenX)
          val markerWidth = maxGreenX - minGreenX + 1
          val markerHeight = maxGreenY - minGreenY + 1
          assertTrue(
            "The source square should not be stretched; rendered marker=${markerWidth}x$markerHeight",
            abs(markerWidth - markerHeight) <= 2,
          )
        } finally {
          rendered.recycle()
        }
      } finally {
        session.close()
      }
    } finally {
      image.delete()
      candidate.delete()
    }
  }

  @Test
  fun jpegIsPreservedUnlessResolutionOrQualityChangesAreRequested() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val detailed = File(context.cacheDir, "image-options-${UUID.randomUUID()}.jpg")
    val small = File(context.cacheDir, "image-small-${UUID.randomUUID()}.jpg")
    writePatternJpeg(detailed, 720, 360)
    writePatternJpeg(small, 20, 10)

    try {
      val page = PdfPageDimensions(144.0, 72.0)
      val defaultBytes = ImagePageEncoder.encode(detailed, page).imageBytes!!
      assertArrayEquals(detailed.readBytes(), defaultBytes)
      assertArrayEquals(defaultBytes, ImagePageEncoder.encode(detailed, page, targetDpi = 400.0).imageBytes)
      val defaultBitmap = decode(defaultBytes)
      try {
        assertEquals(720, defaultBitmap.width)
        assertEquals(360, defaultBitmap.height)
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

  private fun writeA4LimitPatternJpeg(file: File) {
    val bitmap = Bitmap.createBitmap(8000, 300, Bitmap.Config.ARGB_8888)
    try {
      bitmap.eraseColor(Color.DKGRAY)
      val canvas = Canvas(bitmap)
      val paint = Paint()
      paint.color = Color.RED
      canvas.drawRect(0f, 0f, 800f, 300f, paint)
      paint.color = Color.BLUE
      canvas.drawRect(7200f, 0f, 8000f, 300f, paint)
      paint.color = Color.YELLOW
      canvas.drawRect(0f, 0f, 8000f, 60f, paint)
      paint.color = Color.CYAN
      canvas.drawRect(0f, 240f, 8000f, 300f, paint)
      paint.color = Color.GREEN
      canvas.drawRect(3910f, 60f, 4090f, 240f, paint)
      FileOutputStream(file).use { output ->
        assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 100, output))
      }
    } finally {
      bitmap.recycle()
    }
  }

  private fun isRed(color: Int): Boolean =
    Color.red(color) > 140 && Color.green(color) < 100 && Color.blue(color) < 100

  private fun isBlue(color: Int): Boolean =
    Color.blue(color) > 140 && Color.red(color) < 100 && Color.green(color) < 100

  private fun isYellow(color: Int): Boolean =
    Color.red(color) > 140 && Color.green(color) > 140 && Color.blue(color) < 100

  private fun isCyan(color: Int): Boolean =
    Color.green(color) > 140 && Color.blue(color) > 140 && Color.red(color) < 100

  private fun isGreen(color: Int): Boolean =
    Color.green(color) > 120 &&
      Color.green(color).toDouble() > Color.red(color) * 1.4 &&
      Color.green(color).toDouble() > Color.blue(color) * 1.4

  private fun isWhite(color: Int): Boolean =
    Color.red(color) > 230 && Color.green(color) > 230 && Color.blue(color) > 230

}
