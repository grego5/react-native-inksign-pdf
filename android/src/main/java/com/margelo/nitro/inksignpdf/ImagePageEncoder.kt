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
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Preserves supported compressed images; rasterizes for resolution or encoding changes. */
internal object ImagePageEncoder {
  private const val DPI = 200.0
  private const val POINTS_PER_INCH = 72.0
  private const val JPEG_QUALITY = 72
  private const val MAX_PAGE_EDGE_PX = 8192.0

  fun encode(
    source: File,
    page: PdfPageDimensions,
    targetDpi: Double? = null,
    jpegQuality: Double? = null,
  ): PdfiumAppendRequest {
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
    val grayscalePng = isGrayscalePng4(source)
    val supported = bounds.outMimeType == "image/jpeg" || grayscalePng
    val pointsPerSourcePixel = min(
      page.width / orientedWidth,
      page.height / orientedHeight,
    )
    val sourceDpi = POINTS_PER_INCH / pointsPerSourcePixel
    val rasterDpi = min(targetDpi ?: if (supported) sourceDpi else DPI, sourceDpi)
    val requestedPixelsPerPoint = rasterDpi / POINTS_PER_INCH
    val longestPageEdge = max(page.width, page.height)
    val maxPixelsPerPoint = MAX_PAGE_EDGE_PX / longestPageEdge
    val rasterLimitReached = requestedPixelsPerPoint >= maxPixelsPerPoint
    val pixelsPerPoint = min(requestedPixelsPerPoint, maxPixelsPerPoint)
    val targetWidth = if (rasterLimitReached && page.width >= page.height) {
      MAX_PAGE_EDGE_PX.toInt()
    } else {
      pagePixels(page.width, pixelsPerPoint)
    }
    val targetHeight = if (rasterLimitReached && page.height >= page.width) {
      MAX_PAGE_EDGE_PX.toInt()
    } else {
      pagePixels(page.height, pixelsPerPoint)
    }
    val imageTargetWidth = pagePixels(
      orientedWidth * pointsPerSourcePixel,
      pixelsPerPoint,
    )
    val imageTargetHeight = pagePixels(
      orientedHeight * pointsPerSourcePixel,
      pixelsPerPoint,
    )
    if (supported && jpegQuality == null &&
      (targetDpi == null || orientedWidth <= imageTargetWidth && orientedHeight <= imageTargetHeight)
    ) {
      return PdfiumAppendRequest(
        type = PageType.IMAGE, imageBytes = source.readBytes(),
        pageWidth = page.width, pageHeight = page.height,
        placement = preservedPlacement(orientation,
          orientedWidth * pointsPerSourcePixel, orientedHeight * pointsPerSourcePixel, page),
      )
    }
    val keepGrayscale = grayscalePng && jpegQuality == null
    val sample = calculateSample(
      orientedWidth,
      orientedHeight,
      imageTargetWidth,
      imageTargetHeight,
    )
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
      val bytes = if (keepGrayscale) {
        PdfiumPageAssembler.encodeGrayscalePng(pageBitmap)
      } else {
        val output = ByteArrayOutputStream()
        val quality = jpegQuality?.times(100.0)?.roundToInt() ?: JPEG_QUALITY
        check(pageBitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)) {
          "Unable to encode selected image"
        }
        output.toByteArray()
      }
      return PdfiumAppendRequest(
        type = PageType.IMAGE,
        imageBytes = bytes,
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

  private fun preservedPlacement(orientation: Int, width: Double, height: Double,
    page: PdfPageDimensions): PdfiumImagePlacement {
    val unit = when (orientation) {
      2 -> PdfiumImagePlacement(a = -1.0, e = 1.0)
      3 -> PdfiumImagePlacement(a = -1.0, d = -1.0, e = 1.0, f = 1.0)
      4 -> PdfiumImagePlacement(d = -1.0, f = 1.0)
      5 -> PdfiumImagePlacement(a = 0.0, b = -1.0, c = -1.0, d = 0.0, e = 1.0, f = 1.0)
      6 -> PdfiumImagePlacement(a = 0.0, b = -1.0, c = 1.0, d = 0.0, f = 1.0)
      7 -> PdfiumImagePlacement(a = 0.0, b = 1.0, c = 1.0, d = 0.0)
      8 -> PdfiumImagePlacement(a = 0.0, b = 1.0, c = -1.0, d = 0.0, e = 1.0)
      else -> PdfiumImagePlacement()
    }
    return PdfiumImagePlacement(a = unit.a * width, b = unit.b * height,
      c = unit.c * width, d = unit.d * height,
      e = (page.width - width) / 2.0 + unit.e * width,
      f = (page.height - height) / 2.0 + unit.f * height)
  }

  private fun pagePixels(points: Double, pixelsPerPoint: Double): Int =
    ceil(points * pixelsPerPoint).toInt()

  // Encoding admission only; the shared PNG/PDF boundary validates all chunks and samples.
  private fun isGrayscalePng4(source: File): Boolean = source.inputStream().use { input ->
    val header = ByteArray(29)
    var count = 0
    while (count < header.size) {
      val read = input.read(header, count, header.size - count)
      if (read < 0) return@use false
      count += read
    }
    header.copyOfRange(0, 8).contentEquals(byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10)) &&
      header[24] == 4.toByte() && header[25] == 0.toByte() && header[28] == 0.toByte()
  }

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
