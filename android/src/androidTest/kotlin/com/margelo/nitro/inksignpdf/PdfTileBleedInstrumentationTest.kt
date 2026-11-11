package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdfTileBleedInstrumentationTest {
  @Test
  fun renderedTilesHaveNoLightJoinAtFractionalScaleAndTranslation() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val image = File(context.cacheDir, "tile-bleed-${UUID.randomUUID()}.jpg")
    val candidate = File(context.cacheDir, "tile-bleed-${UUID.randomUUID()}.pdf")
    val sourceBitmap = Bitmap.createBitmap(1800, 1800, Bitmap.Config.ARGB_8888)
    try {
      sourceBitmap.eraseColor(Color.rgb(220, 24, 32))
      FileOutputStream(image).use { output ->
        assertTrue(sourceBitmap.compress(Bitmap.CompressFormat.JPEG, 95, output))
      }
      val imageInput = ImagePageEncoder.encode(image, PdfPageDimensions(600.0, 600.0))
      PdfiumPageAssembler.assemble(
        input = null,
        request = PdfiumAssemblyRequest(
          operation = PdfiumAssemblyOperation.CREATE,
          appendInputs = listOf(imageInput),
        ),
        scratch = candidate,
      )

      val tileScale = 2.0
      val window = fullTileWindow(pageWidthPx = 1200, pageHeightPx = 1200, scale = tileScale)
      val requests = PdfTileGrid.requests(window)
      val session = PdfSession.open(candidate.absolutePath, generation = 1L)
      val tiles = try {
        session.renderTiles(requests) {}
      } finally {
        session.close()
      }

      val displayed = Bitmap.createBitmap(1100, 1100, Bitmap.Config.ARGB_8888)
      try {
        val canvas = Canvas(displayed)
        canvas.drawColor(Color.WHITE)
        val displayScale = 1.75 / tileScale
        val pageOffsetX = 21.25
        val pageOffsetY = 14.75
        val rasterRect = RectF()
        val coreRect = RectF()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
          isFilterBitmap = true
          isDither = true
        }
        tiles.forEach { tile ->
          drawPdfTile(
            canvas = canvas,
            tile = tile,
            pageToViewX = pageOffsetX,
            pageToViewY = pageOffsetY,
            tileToViewScale = displayScale,
            rasterRect = rasterRect,
            coreRect = coreRect,
            paint = paint,
          )
        }

        for (edgePx in listOf(512, 1024)) {
          val verticalX = (pageOffsetX + edgePx * displayScale).toInt()
          for (x in verticalX - 2..verticalX + 2) {
            for (y in 45..1055 step 5) assertRed(displayed.getPixel(x, y))
          }
          val horizontalY = (pageOffsetY + edgePx * displayScale).toInt()
          for (y in horizontalY - 2..horizontalY + 2) {
            for (x in 45..1055 step 5) assertRed(displayed.getPixel(x, y))
          }
        }
      } finally {
        displayed.recycle()
        tiles.forEach { it.bitmap.recycle() }
      }
    } finally {
      sourceBitmap.recycle()
      image.delete()
      candidate.delete()
    }
  }

  private fun assertRed(color: Int) {
    assertTrue(
      "A tile join rendered a light pixel: #${Integer.toHexString(color)}",
      Color.red(color) > 170 && Color.green(color) < 100 && Color.blue(color) < 100,
    )
  }

  private fun fullTileWindow(pageWidthPx: Int, pageHeightPx: Int, scale: Double): PdfTileWindow {
    val columns = (pageWidthPx + androidPdfTileSizePx - 1) / androidPdfTileSizePx
    val rows = (pageHeightPx + androidPdfTileSizePx - 1) / androidPdfTileSizePx
    return PdfTileWindow(
      generation = 1L,
      pageSwitchId = 1L,
      pageIndex = 0,
      level = 2,
      scale = scale,
      pageWidthPx = pageWidthPx,
      pageHeightPx = pageHeightPx,
      columns = columns,
      rows = rows,
      firstColumn = 0,
      lastColumn = columns - 1,
      firstRow = 0,
      lastRow = rows - 1,
      firstVisibleColumn = 0,
      lastVisibleColumn = columns - 1,
      firstVisibleRow = 0,
      lastVisibleRow = rows - 1,
    )
  }

  companion object {
    @JvmStatic
    @BeforeClass
    fun loadNativeLibrary() {
      NativeTestRuntime.initialize()
    }
  }
}
