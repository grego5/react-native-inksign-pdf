package com.margelo.nitro.inksignpdf

import java.nio.ByteBuffer
import java.nio.ByteOrder

internal data class PdfiumPoint(
  val x: Double,
  val y: Double,
)

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

internal data class PdfiumRgbaColor(
  val red: Int,
  val green: Int,
  val blue: Int,
  val alpha: Int,
)

internal data class PdfiumFontMetadata(
  val family: String,
  val flags: Int,
  val weight: Int,
)

internal data class PdfiumPositionedCharacter(
  val sourceIndex: Int,
  val textObjectOrdinal: Long,
  val unicode: Long,
  val generated: Boolean,
  val unicodeMapError: Boolean,
  val font: PdfiumFontMetadata,
  val fillColor: PdfiumRgbaColor?,
  val strokeColor: PdfiumRgbaColor?,
  val renderMode: Int,
  val nextDisplacement: PdfiumPoint?,
  val origin: PdfiumPoint,
  val bounds: PdfiumRect,
  val matrix: PdfiumAffineMatrix,
  val fontSize: Double,
)

internal data class PdfiumPageGeometry(
  val pageIndex: Int,
  val pageBounds: PdfiumRect,
  val characters: List<PdfiumPositionedCharacter>,
)

/**
 * Worker-owned bridge to one detached PDFium document session. Native page and
 * text handles never cross this boundary; extraction returns a copied payload
 * which is decoded into immutable Kotlin values.
 */
internal class PdfiumGeometrySession private constructor(
  private var nativeHandle: Long,
  val pageCount: Int,
) : AutoCloseable {
  fun extractPage(pageIndex: Int): PdfiumPageGeometry {
    check(pageIndex in 0 until pageCount) { "Invalid PDFium page index: $pageIndex" }
    val handle = nativeHandle
    if (handle == 0L) {
      throw PdfSessionException("pdfium_closed", "The PDFium geometry session is closed")
    }
    val payload = nativeExtractPage(handle, pageIndex)
      ?: throw PdfSessionException(
        "pdfium_extract_failed",
        "PDFium could not extract page geometry",
      )
    return try {
      PayloadReader(payload).readPage()
    } catch (error: PdfSessionException) {
      throw error
    } catch (error: RuntimeException) {
      throw PdfSessionException(
        "pdfium_extract_failed",
        "PDFium returned an invalid geometry payload",
        error,
      )
    }
  }

  override fun close() {
    val handle = nativeHandle
    if (handle == 0L) return
    nativeHandle = 0L
    nativeClose(handle)
  }

  companion object {
    fun open(documentBytes: ByteArray): PdfiumGeometrySession {
      require(documentBytes.isNotEmpty()) { "PDFium requires non-empty document bytes" }
      val handle = nativeOpen(documentBytes)
      if (handle == 0L) {
        throw PdfSessionException("pdfium_open_failed", "PDFium could not open the document")
      }
      val pageCount = nativePageCount(handle)
      if (pageCount <= 0) {
        nativeClose(handle)
        throw PdfSessionException("pdfium_open_failed", "PDFium reported no pages")
      }
      return PdfiumGeometrySession(handle, pageCount)
    }

    @JvmStatic
    private external fun nativeOpen(documentBytes: ByteArray): Long

    @JvmStatic
    private external fun nativePageCount(handle: Long): Int

    @JvmStatic
    private external fun nativeExtractPage(handle: Long, pageIndex: Int): ByteArray?

    @JvmStatic
    private external fun nativeClose(handle: Long)
  }
}

private class PayloadReader(payload: ByteArray) {
  private val buffer = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)

  fun readPage(): PdfiumPageGeometry {
    check(readInt() == 0x31504750) { "Unexpected PDFium geometry payload" }
    val pageIndex = readInt()
    val pageBounds = readRect()
    val characterCount = readCount()
    val characters = ArrayList<PdfiumPositionedCharacter>(characterCount)
    repeat(characterCount) { characters += readCharacter() }
    check(!buffer.hasRemaining()) { "Trailing PDFium geometry payload" }
    return PdfiumPageGeometry(pageIndex, pageBounds, characters.toList())
  }

  private fun readCharacter(): PdfiumPositionedCharacter {
    val sourceIndex = readInt()
    val textObjectOrdinal = readUInt()
    val unicode = readUInt()
    val flags = readUInt()
    val font = PdfiumFontMetadata(readString(), readInt(), readInt())
    val renderMode = readInt()
    val fillColor = readColor()
    val strokeColor = readColor()
    val nextDisplacement = if (readFlag()) PdfiumPoint(readDouble(), readDouble()) else null
    val origin = PdfiumPoint(readDouble(), readDouble())
    val bounds = readRect()
    val matrix = PdfiumAffineMatrix(
      readDouble(), readDouble(), readDouble(),
      readDouble(), readDouble(), readDouble(),
    )
    return PdfiumPositionedCharacter(
      sourceIndex = sourceIndex,
      textObjectOrdinal = textObjectOrdinal,
      unicode = unicode,
      generated = flags and 1L != 0L,
      unicodeMapError = flags and 2L != 0L,
      font = font,
      fillColor = fillColor,
      strokeColor = strokeColor,
      renderMode = renderMode,
      nextDisplacement = nextDisplacement,
      origin = origin,
      bounds = bounds,
      matrix = matrix,
      fontSize = readDouble(),
    )
  }

  private fun readRect() = PdfiumRect(readDouble(), readDouble(), readDouble(), readDouble())

  private fun readColor(): PdfiumRgbaColor? {
    if (!readFlag()) return null
    return PdfiumRgbaColor(readByte(), readByte(), readByte(), readByte())
  }

  private fun readString(): String {
    val length = readCount()
    requireRemaining(length)
    val bytes = ByteArray(length)
    buffer.get(bytes)
    return bytes.toString(Charsets.UTF_8)
  }

  private fun readFlag(): Boolean = readByte() != 0

  private fun readByte(): Int {
    requireRemaining(1)
    return buffer.get().toInt() and 0xff
  }

  private fun readInt(): Int {
    requireRemaining(Int.SIZE_BYTES)
    return buffer.int
  }

  private fun readUInt(): Long {
    requireRemaining(Int.SIZE_BYTES)
    return buffer.int.toLong() and 0xffff_ffffL
  }

  private fun readDouble(): Double {
    requireRemaining(Double.SIZE_BYTES)
    return buffer.double
  }

  private fun readCount(): Int {
    val count = readUInt()
    require(count <= Int.MAX_VALUE) { "PDFium geometry payload is too large" }
    return count.toInt()
  }

  private fun requireRemaining(bytes: Int) {
    require(bytes >= 0 && buffer.remaining() >= bytes) {
      "Truncated PDFium geometry payload"
    }
  }
}
