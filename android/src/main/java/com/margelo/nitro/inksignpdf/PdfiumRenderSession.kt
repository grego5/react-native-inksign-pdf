package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap

internal data class PdfiumRect(
  val left: Double,
  val top: Double,
  val right: Double,
  val bottom: Double,
)

internal data class PdfiumAffineMatrix(
  val a: Double,
  val b: Double,
  val c: Double,
  val d: Double,
  val e: Double,
  val f: Double,
)

internal data class PdfiumPageSize(
  val width: Double,
  val height: Double,
)

internal data class PdfiumHorizontalSnapCandidate(
  val left: Double,
  val right: Double,
  val y: Double,
)

internal data class PdfiumTextKeyMatch(
  val left: Double,
  val top: Double,
  val right: Double,
  val bottom: Double,
  val sourceIndex: Double,
  val lineCenter: Double,
  val lineHeight: Double,
)

internal data class PdfiumTextKeyLookup(
  val hasLiteralMatch: Boolean,
  val matches: List<PdfiumTextKeyMatch>,
)

/** Worker-owned bridge to one detached PDFium document session. */
internal class PdfiumRenderSession private constructor(
  private var nativeHandle: Long,
  val pageCount: Int,
) : AutoCloseable {
  fun horizontalSnapCandidates(pageIndex: Int): List<PdfiumHorizontalSnapCandidate> {
    check(pageIndex in 0 until pageCount) { "Invalid PDFium page index: $pageIndex" }
    val handle = nativeHandle
    if (handle == 0L) {
      throw PdfSessionException("pdfium_closed", "The PDFium render session is closed")
    }
    val values = nativeHorizontalSnapCandidates(handle, pageIndex) ?: DoubleArray(0)
    check(values.size % 3 == 0) { "PDFium returned incomplete snap candidate data" }
    return List(values.size / 3) { index ->
      val offset = index * 3
      PdfiumHorizontalSnapCandidate(values[offset], values[offset + 1], values[offset + 2])
    }
  }

  fun textKeyMatches(pageIndex: Int, key: String): List<PdfiumTextKeyMatch> {
    return textKeyLookup(pageIndex, key).matches
  }

  fun textKeyLookup(pageIndex: Int, key: String): PdfiumTextKeyLookup {
    check(pageIndex in 0 until pageCount) { "Invalid PDFium page index: $pageIndex" }
    val handle = nativeHandle
    if (handle == 0L) throw PdfSessionException("pdfium_closed", "The PDFium render session is closed")
    val values = nativeTextKeyMatches(handle, pageIndex, key) ?: DoubleArray(0)
    check(values.isNotEmpty() && (values.size - 1) % 7 == 0) {
      "PDFium returned incomplete text key lookup data"
    }
    val matches = List((values.size - 1) / 7) { index ->
      val offset = 1 + index * 7
      PdfiumTextKeyMatch(values[offset], values[offset + 1], values[offset + 2],
        values[offset + 3], values[offset + 4], values[offset + 5], values[offset + 6])
    }
    return PdfiumTextKeyLookup(values[0] == 1.0, matches)
  }

  internal fun pageAnalysisScanCountsForTesting(): LongArray {
    val handle = nativeHandle
    if (handle == 0L) throw PdfSessionException("pdfium_closed", "The PDFium render session is closed")
    return nativePageAnalysisScanCountsForTesting(handle)
      ?: throw PdfSessionException("pdfium_closed", "The PDFium render session is closed")
  }

  fun pageSize(pageIndex: Int): PdfiumPageSize {
    check(pageIndex in 0 until pageCount) { "Invalid PDFium page index: $pageIndex" }
    val handle = nativeHandle
    if (handle == 0L) {
      throw PdfSessionException("pdfium_closed", "The PDFium render session is closed")
    }
    val dimensions = nativePageDimensions(handle, pageIndex)
      ?: throw PdfSessionException(
        "pdfium_page_info_failed",
        "PDFium could not read page dimensions",
      )
    require(dimensions.size == 2 && dimensions[0].isFinite() && dimensions[0] > 0.0 &&
      dimensions[1].isFinite() && dimensions[1] > 0.0) {
      "PDFium returned invalid page dimensions"
    }
    return PdfiumPageSize(dimensions[0], dimensions[1])
  }

  fun renderPageIntoBitmap(
    pageIndex: Int,
    bitmap: Bitmap,
    pageToDevice: PdfiumAffineMatrix,
    clip: PdfiumRect,
    background: Int = 0xFFFFFFFF.toInt(),
    flags: Int = 0,
  ): Boolean {
    check(pageIndex in 0 until pageCount) { "Invalid PDFium page index: $pageIndex" }
    val handle = nativeHandle
    if (handle == 0L) {
      throw PdfSessionException("pdfium_closed", "The PDFium render session is closed")
    }
    return nativeRenderPageIntoBitmap(
      handle,
      pageIndex,
      bitmap,
      pageToDevice.a,
      pageToDevice.b,
      pageToDevice.c,
      pageToDevice.d,
      pageToDevice.e,
      pageToDevice.f,
      clip.left,
      clip.top,
      clip.right,
      clip.bottom,
      background,
      flags,
    )
  }

  override fun close() {
    val handle = nativeHandle
    if (handle == 0L) return
    nativeHandle = 0L
    nativeClose(handle)
  }

  companion object {
    fun open(
      documentBytes: ByteArray,
      fallbackFont: PdfFallbackFont? = null,
    ): PdfiumRenderSession {
      require(documentBytes.isNotEmpty()) { "PDFium requires non-empty document bytes" }
      val fallbackPath = fallbackFont?.path
      val fallbackCollectionIndex = fallbackFont?.collectionIndex ?: 0.0
      val handle = try {
        nativeOpen(documentBytes, fallbackPath, fallbackCollectionIndex)
      } catch (error: IllegalArgumentException) {
        throw PdfSessionException(
          "invalid_fallback_font",
          error.message ?: "Invalid fallback font configuration",
          error,
        )
      } catch (error: IllegalStateException) {
        throw PdfSessionException(
          "pdfium_open_failed",
          error.message ?: "PDFium document open failed",
          error,
        )
      }
      if (handle == 0L) {
        throw PdfSessionException("pdfium_open_failed", "PDFium could not open the document")
      }
      val pageCount = nativePageCount(handle)
      if (pageCount <= 0) {
        nativeClose(handle)
        throw PdfSessionException("pdfium_open_failed", "PDFium reported no pages")
      }
      return PdfiumRenderSession(handle, pageCount)
    }

    @JvmStatic
    private external fun nativeOpen(
      documentBytes: ByteArray,
      fallbackPath: String?,
      fallbackCollectionIndex: Double,
    ): Long

    @JvmStatic
    private external fun nativePageCount(handle: Long): Int

    @JvmStatic
    private external fun nativePageDimensions(handle: Long, pageIndex: Int): DoubleArray?

    @JvmStatic
    private external fun nativeHorizontalSnapCandidates(
      handle: Long,
      pageIndex: Int,
    ): DoubleArray?

    @JvmStatic
    private external fun nativeTextKeyMatches(
      handle: Long,
      pageIndex: Int,
      key: String,
    ): DoubleArray?

    @JvmStatic
    private external fun nativePageAnalysisScanCountsForTesting(handle: Long): LongArray?

    @JvmStatic
    private external fun nativeRenderPageIntoBitmap(
      handle: Long,
      pageIndex: Int,
      bitmap: Bitmap,
      a: Double,
      b: Double,
      c: Double,
      d: Double,
      e: Double,
      f: Double,
      clipLeft: Double,
      clipTop: Double,
      clipRight: Double,
      clipBottom: Double,
      background: Int,
      flags: Int,
    ): Boolean

    @JvmStatic
    private external fun nativeClose(handle: Long)
  }
}
