package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.ceil
import kotlin.math.min

/** Converts one selected image into the page-sized JPEG consumed by PDFium. */
internal object ImagePageEncoder {
  private const val DPI = 200.0
  private const val POINTS_PER_INCH = 72.0
  private const val JPEG_QUALITY = 72
  private const val MAX_PAGE_DIMENSION_PX = 8192.0

  fun encode(source: File, page: PdfPageDimensions): PdfiumAppendRequest {
    require(page.width.isFinite() && page.width > 0.0 &&
      page.height.isFinite() && page.height > 0.0)
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(source.absolutePath, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
      throw PdfSessionException("unsupported_content", "The selected image is unreadable")
    }

    val exif = try {
      ExifInterface(source.absolutePath)
    } catch (error: Exception) {
      throw PdfSessionException("unsupported_content", "The selected image metadata is unreadable", error)
    }
    val orientation = exif.getAttributeInt(
      ExifInterface.TAG_ORIENTATION,
      ExifInterface.ORIENTATION_NORMAL,
    )
    val rotation = when (orientation) {
      ExifInterface.ORIENTATION_ROTATE_90 -> 90
      ExifInterface.ORIENTATION_ROTATE_180 -> 180
      ExifInterface.ORIENTATION_ROTATE_270 -> 270
      else -> 0
    }
    val rotatedDimensions = rotation == 90 || rotation == 270 ||
      orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
      orientation == ExifInterface.ORIENTATION_TRANSVERSE
    val orientedWidth = if (rotatedDimensions) bounds.outHeight else bounds.outWidth
    val orientedHeight = if (rotatedDimensions) bounds.outWidth else bounds.outHeight
    val targetWidth = pagePixels(page.width)
    val targetHeight = pagePixels(page.height)
    val sample = calculateSample(orientedWidth, orientedHeight, targetWidth, targetHeight)
    val decoded = BitmapFactory.decodeFile(
      source.absolutePath,
      BitmapFactory.Options().apply {
        inSampleSize = sample
        inPreferredConfig = Bitmap.Config.ARGB_8888
      },
    ) ?: throw PdfSessionException("unsupported_content", "The selected image is unreadable")

    var oriented: Bitmap? = null
    var canvasBitmap: Bitmap? = null
    try {
      val transform = Matrix().apply {
        when (orientation) {
          ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> postScale(-1f, 1f)
          ExifInterface.ORIENTATION_FLIP_VERTICAL -> postScale(1f, -1f)
          ExifInterface.ORIENTATION_TRANSPOSE -> {
            postRotate(90f)
            postScale(-1f, 1f)
          }
          ExifInterface.ORIENTATION_TRANSVERSE -> {
            postRotate(270f)
            postScale(-1f, 1f)
          }
        }
        if (orientation != ExifInterface.ORIENTATION_TRANSPOSE &&
          orientation != ExifInterface.ORIENTATION_TRANSVERSE && rotation != 0
        ) postRotate(rotation.toFloat())
      }
      val orientedBitmap = Bitmap.createBitmap(
        decoded,
        0,
        0,
        decoded.width,
        decoded.height,
        transform,
        true,
      )
      oriented = orientedBitmap
      if (orientedBitmap !== decoded) decoded.recycle()

      val pageBitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
      canvasBitmap = pageBitmap
      Canvas(pageBitmap).apply {
        drawColor(Color.WHITE)
        val scale = min(
          targetWidth.toDouble() / orientedBitmap.width,
          targetHeight.toDouble() / orientedBitmap.height,
        )
        val drawWidth = orientedBitmap.width * scale
        val drawHeight = orientedBitmap.height * scale
        val left = (targetWidth - drawWidth) / 2.0
        val top = (targetHeight - drawHeight) / 2.0
        drawBitmap(
          orientedBitmap,
          null,
          android.graphics.RectF(
            left.toFloat(),
            top.toFloat(),
            (left + drawWidth).toFloat(),
            (top + drawHeight).toFloat(),
          ),
          Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG),
        )
      }
      val output = ByteArrayOutputStream()
      check(pageBitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)) {
        "Unable to encode selected image"
      }
      return PdfiumAppendRequest(
        type = PageType.IMAGE,
        imageBytes = output.toByteArray(),
        pageWidth = page.width,
        pageHeight = page.height,
        placement = PdfiumImagePlacement(
          a = page.width,
          d = page.height,
        ),
      )
    } finally {
      if (oriented != null && !oriented.isRecycled) oriented.recycle()
      if (canvasBitmap != null && !canvasBitmap.isRecycled) canvasBitmap.recycle()
      if (!decoded.isRecycled) decoded.recycle()
    }
  }

  private fun pagePixels(points: Double): Int =
    ceil(points * DPI / POINTS_PER_INCH)
      .coerceIn(1.0, MAX_PAGE_DIMENSION_PX)
      .toInt()

  private fun calculateSample(
    width: Int,
    height: Int,
    targetWidth: Int,
    targetHeight: Int,
  ): Int {
    var sample = 1
    while (width / (sample * 2) >= targetWidth && height / (sample * 2) >= targetHeight) {
      sample *= 2
    }
    return sample
  }
}
