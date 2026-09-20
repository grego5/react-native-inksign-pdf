package com.margelo.nitro.inksignpdf

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class InkDisplayBatchTest {
  @Test
  fun boundsUseFloorMinAndCeilMaxWithoutPadding() {
    val path = Path().apply {
      moveTo(-1.25f, 2.75f)
      lineTo(3.2f, 5.01f)
      close()
    }
    val batch = InkDisplayBatch("test-bounds")
    batch.appendPath(path, segmentCount = 3, verbCount = 4)

    assertArrayEquals(intArrayOf(-2, 2, 4, 6), batch.boundsForTest())
  }

  @Test
  fun softwareCanvasUsesRetainedSourcePathWithoutDisplayList() {
    val path = Path().apply {
      moveTo(10f, 10f)
      lineTo(20f, 10f)
      lineTo(20f, 20f)
      close()
    }
    val batch = InkDisplayBatch("test-software")
    batch.appendPath(path, segmentCount = 3, verbCount = 4)
    val canvas = Canvas(android.graphics.Bitmap.createBitmap(
      32,
      32,
      android.graphics.Bitmap.Config.ARGB_8888,
    ))
    canvas.drawColor(Color.WHITE)
    batch.draw(canvas, Paint().apply { color = Color.BLACK }, hardware = false)

    assertFalse(batch.hasDisplayListForTest())
    assertTrue(canvas.isHardwareAccelerated.not())
  }

  @Test
  fun zeroWidthAndHeightBoundsRemainExact() {
    val path = Path().apply {
      moveTo(4.0f, 7.0f)
      lineTo(4.0f, 7.0f)
    }
    val batch = InkDisplayBatch("test-degenerate")
    batch.appendPath(path, segmentCount = 2, verbCount = 2)

    assertArrayEquals(intArrayOf(4, 7, 4, 7), batch.boundsForTest())
  }

}
