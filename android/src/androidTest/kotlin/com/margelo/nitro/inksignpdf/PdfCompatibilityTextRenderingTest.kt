package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.pdf.PdfRendererPreV
import android.graphics.pdf.RenderParams
import android.graphics.pdf.component.PdfPageTextObject
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.ext.SdkExtensions
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class PdfCompatibilityTextRenderingTest {
  @Test
  fun overlayAddsNonAsciiGlyphsAndLeavesSourceAsciiAndBorderUntouched() {
    assumeSupportedRenderer()
    withFixture { source ->
      val request = request(width = 240, height = 160, scale = 1.0)
      val baseline = renderDirect(source, request)
      val overlay = renderSession(source, request)
      try {
        assertRegionEquals(baseline, overlay, Rect(24, 42, 88, 76))
        assertRegionEquals(baseline, overlay, Rect(9, 9, 231, 13))
        assertRegionEquals(baseline, overlay, Rect(9, 9, 13, 151))
        assertTrue(
          "non-ASCII region should gain compatibility pixels",
          darkPixelCount(overlay, Rect(88, 42, 145, 76)) >
            darkPixelCount(baseline, Rect(88, 42, 145, 76)),
        )
      } finally {
        baseline.recycle()
        overlay.recycle()
      }
    }
  }

  @Test
  fun overlayFollowsCanonicalPlacementAtTwoTileScales() {
    assumeSupportedRenderer()
    withFixture { source ->
      val oneX = renderSession(source, request(width = 240, height = 160, scale = 1.0))
      val twoX = renderSession(source, request(width = 480, height = 320, scale = 2.0))
      try {
        val oneBounds = requireNotNull(darkBounds(oneX, Rect(88, 42, 145, 76)))
        val twoBounds = requireNotNull(darkBounds(twoX, Rect(176, 84, 290, 152)))
        assertTrue(abs(twoBounds.left - oneBounds.left * 2) <= 3)
        assertTrue(abs(twoBounds.top - oneBounds.top * 2) <= 3)
        assertTrue(abs(twoBounds.right - oneBounds.right * 2) <= 4)
        assertTrue(abs(twoBounds.bottom - oneBounds.bottom * 2) <= 4)
      } finally {
        oneX.recycle()
        twoX.recycle()
      }
    }
  }

  @Test
  fun overlayUsesTheSameTranslationForAnOffsetTile() {
    assumeSupportedRenderer()
    withFixture { source ->
      val full = renderSession(source, request(width = 240, height = 160, scale = 1.0))
      val offset = renderSession(
        source,
        request(width = 100, height = 70, scale = 1.0, left = 72, top = 32),
      )
      try {
        for (y in 0 until offset.height) {
          for (x in 0 until offset.width) {
            assertEquals(
              "offset tile mismatch at ($x,$y)",
              full.getPixel(x + 72, y + 32),
              offset.getPixel(x, y),
            )
          }
        }
      } finally {
        full.recycle()
        offset.recycle()
      }
    }
  }

  @Test
  fun previewDelegatesToTheSameOverlayRenderingPath() {
    assumeSupportedRenderer()
    withFixture { source ->
      val request = request(width = 240, height = 160, scale = 1.0)
      val session = PdfSession.open(source.path, generation = 1L)
      try {
        val tile = session.renderTiles(listOf(request)) { }.single()
        val repeated = session.renderTiles(listOf(request)) { }.single()
        val preview = session.renderPreview(request) { }
        try {
          assertTrue(tile.bitmap.sameAs(repeated.bitmap))
          assertTrue(tile.bitmap.sameAs(preview.bitmap))
        } finally {
          tile.bitmap.recycle()
          repeated.bitmap.recycle()
          preview.bitmap.recycle()
        }
      } finally {
        session.close()
      }
    }
  }

  private fun assumeSupportedRenderer() {
    assumeTrue(
      "PdfRendererPreV requires Android S extension 18",
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
        SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 18,
    )
  }

  private fun withFixture(block: (File) -> Unit) {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val source = File.createTempFile("pdf-font-overlay-", ".pdf", context.cacheDir)
    try {
      context.assets.open(FIXTURE_ASSET).use { input ->
        source.outputStream().use { output -> input.copyTo(output) }
      }
      ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
        PdfRendererPreV(descriptor).use { renderer ->
          renderer.openPage(0).use { page ->
            assumeTrue(
              "PdfRendererPreV did not expose supported text page objects",
              page.getPageObjects().any { it.second is PdfPageTextObject },
            )
          }
        }
      }
      block(source)
    } finally {
      source.delete()
    }
  }

  private fun request(
    width: Int,
    height: Int,
    scale: Double,
    left: Int = 0,
    top: Int = 0,
  ): PdfTileRequest {
    return PdfTileRequest(
      key = PdfTileKey(
        generation = 1L,
        pageSwitchId = 1L,
        pageIndex = 0,
        level = 0,
        x = 0,
        y = 0,
      ),
      leftPx = left,
      topPx = top,
      widthPx = width,
      heightPx = height,
      scale = scale,
      priority = androidPdfTileVisiblePriority,
    )
  }

  private fun renderSession(source: File, request: PdfTileRequest): Bitmap {
    val session = PdfSession.open(source.path, generation = 1L)
    return try {
      session.renderTiles(listOf(request)) { }.single().bitmap
    } finally {
      session.close()
    }
  }

  private fun renderDirect(source: File, request: PdfTileRequest): Bitmap {
    val bitmap = Bitmap.createBitmap(request.widthPx, request.heightPx, Bitmap.Config.ARGB_8888)
    try {
      ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
        PdfRendererPreV(descriptor).use { renderer ->
          renderer.openPage(0).use { page ->
            val transform = Matrix().apply {
              setScale(request.scale.toFloat(), request.scale.toFloat())
              postTranslate(-request.leftPx.toFloat(), -request.topPx.toFloat())
            }
            page.render(
              bitmap,
              null,
              transform,
              RenderParams.Builder(RenderParams.RENDER_MODE_FOR_DISPLAY).build(),
            )
          }
        }
      }
      return bitmap
    } catch (error: Throwable) {
      bitmap.recycle()
      throw error
    }
  }

  private fun assertRegionEquals(first: Bitmap, second: Bitmap, region: Rect) {
    for (y in region.top until region.bottom) {
      for (x in region.left until region.right) {
        assertEquals("pixel mismatch at ($x,$y)", first.getPixel(x, y), second.getPixel(x, y))
      }
    }
  }

  private fun darkPixelCount(bitmap: Bitmap, region: Rect): Int {
    var count = 0
    for (y in region.top until region.bottom) {
      for (x in region.left until region.right) {
        val pixel = bitmap.getPixel(x, y)
        if (android.graphics.Color.alpha(pixel) > 0 && android.graphics.Color.red(pixel) < 245) {
          count += 1
        }
      }
    }
    return count
  }

  private fun darkBounds(bitmap: Bitmap, region: Rect): Rect? {
    var bounds: Rect? = null
    for (y in region.top until region.bottom) {
      for (x in region.left until region.right) {
        val pixel = bitmap.getPixel(x, y)
        if (android.graphics.Color.alpha(pixel) > 0 && android.graphics.Color.red(pixel) < 245) {
          if (bounds == null) bounds = Rect(x, y, x + 1, y + 1)
          else bounds?.union(x, y, x + 1, y + 1)
        }
      }
    }
    return bounds
  }

  private companion object {
    const val FIXTURE_ASSET = "nonembedded-identity-text.pdf"
  }
}
