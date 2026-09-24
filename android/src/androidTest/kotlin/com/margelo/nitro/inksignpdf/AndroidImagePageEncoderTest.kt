package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidImagePageEncoderTest {
  @Test
  fun squareImageUsesWhiteContainBackground() {
    val source = temporaryJpeg(width = 20, height = 20)
    try {
      val encoded = ImagePageEncoder.encode(source, PdfPageDimensions(72.0, 144.0))
      val bytes = checkNotNull(encoded.imageBytes)
      val bitmap = checkNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
      try {
        assertEquals(200, bitmap.width)
        assertEquals(400, bitmap.height)
        assertTrue(isNearlyWhite(bitmap.getPixel(10, 10)))
        assertTrue(Color.red(bitmap.getPixel(100, 200)) > 180)
      } finally {
        bitmap.recycle()
      }
    } finally {
      source.delete()
    }
  }

  @Test
  fun exifRotationIsAppliedBeforeAspectFit() {
    val source = temporaryJpeg(width = 40, height = 20)
    try {
      ExifInterface(source.absolutePath).apply {
        setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
        saveAttributes()
      }
      val encoded = ImagePageEncoder.encode(source, PdfPageDimensions(72.0, 144.0))
      val bytes = checkNotNull(encoded.imageBytes)
      val bitmap = checkNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
      try {
        assertTrue(Color.red(bitmap.getPixel(10, 10)) > 150)
        assertTrue(Color.red(bitmap.getPixel(bitmap.width - 10, bitmap.height - 10)) > 150)
      } finally {
        bitmap.recycle()
      }
    } finally {
      source.delete()
    }
  }

  private fun temporaryJpeg(width: Int, height: Int): File {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val file = File(context.cacheDir, "encoder-${UUID.randomUUID()}.jpg")
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    bitmap.eraseColor(Color.RED)
    FileOutputStream(file).use { output ->
      check(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, output))
    }
    bitmap.recycle()
    return file
  }

  private fun isNearlyWhite(color: Int): Boolean =
    Color.red(color) > 240 && Color.green(color) > 240 && Color.blue(color) > 240
}
