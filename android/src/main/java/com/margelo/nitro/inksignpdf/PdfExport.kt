package com.margelo.nitro.inksignpdf

import android.graphics.fonts.Font
import android.os.Build
import android.text.TextPaint
import android.graphics.text.TextRunShaper
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.text.Bidi

/** UI-thread snapshot consumed by the worker-owned vector exporter. */
internal data class PdfPageExportSnapshot(
  val pageIndex: Int,
  val dimensions: PdfPageDimensions,
  val strokes: List<StrokeOutline>,
  val textAnnotations: List<TextAnnotation> = emptyList(),
)

internal data class PdfExportSnapshot(
  val sourcePath: String,
  val outputPath: String,
  val pages: List<PdfPageExportSnapshot>,
  val generation: Long,
  val color: Int,
) {
  init {
    require(pages.isNotEmpty())
    require(pages.mapIndexed { index, page -> index == page.pageIndex }.all { it })
  }
}

/** Writes paths and text through PDFium, then atomically publishes its validated candidate. */
internal object PdfExporter {
  fun export(
    snapshot: PdfExportSnapshot,
    artifactPolicy: DocumentArtifactPolicy,
    isStale: () -> Boolean,
  ): String {
    ensureExportFresh(isStale, snapshot.generation)
    val source = File(snapshot.sourcePath)
    val output = artifactPolicy.validatedSignedOutput(snapshot.outputPath, source)
    var temporary: File? = null
    try {
      if (!source.isFile || !source.canRead()) {
        throw exportFailed("The opened source PDF is no longer readable")
      }
      val candidate = artifactPolicy.allocateExportScratch()
      temporary = candidate
      val text = PdfExportTextResolver.resolve(snapshot)
      InkPerfetto.section("InkSign/export PDFium write and validate") {
        PdfiumNativePdfExporter.export(snapshot, text, candidate)
      }
      ensureExportFresh(isStale, snapshot.generation)
      moveAtomically(candidate, output)
      temporary = null
      return output.path
    } catch (error: PdfSessionException) {
      throw error
    } catch (error: Throwable) {
      throw exportFailed("Unable to export the PDF", error)
    } finally {
      temporary?.let(artifactPolicy::deleteExact)
    }
  }

  private fun moveAtomically(source: File, destination: File) {
    try {
      Files.move(
        source.toPath(),
        destination.toPath(),
        StandardCopyOption.ATOMIC_MOVE,
        StandardCopyOption.REPLACE_EXISTING,
      )
    } catch (error: AtomicMoveNotSupportedException) {
      throw exportFailed("The destination filesystem does not support atomic replacement", error)
    } catch (error: IOException) {
      throw exportFailed("Unable to replace the export destination", error)
    }
  }
}

internal data class PdfiumTextRunEntry(
  val pageIndex: Int,
  val lineId: Int,
  val text: String,
  val sourceStart: Int,
  val sourceLength: Int,
  val bidiLevel: Int,
  val visualOrder: Int,
  val baseDirectionRtl: Boolean,
  /** -1 selects PDFium's best-effort fallback font. */
  val fontIndex: Int,
  val boundsLeft: Float,
  val boundsRight: Float,
  val baselineFromTop: Float,
  val fontSize: Float,
  val estimatedAdvance: Float,
  val color: Int,
)

internal data class PdfiumFontResource(
  val bytes: ByteArray,
  val collectionIndex: Int,
  val fsType: Int,
)

internal data class PdfiumTextSnapshot(
  val fonts: List<PdfiumFontResource>,
  val runs: List<PdfiumTextRunEntry>,
)

/** Selects Android fallback fonts; PDFium's linked HarfBuzz performs cluster-aware shaping. */
internal object PdfExportTextResolver {
  private data class FontKey(val sourceIdentifier: Int, val collectionIndex: Int)
  private data class SourceUnit(
    val start: Int,
    val end: Int,
    val codePoint: Int,
    val bidiLevel: Int,
    val script: Character.UnicodeScript,
    var fontIndex: Int,
  )
  private data class TextSegment(
    val sourceStart: Int,
    val sourceLength: Int,
    val bidiLevel: Int,
    val script: Character.UnicodeScript,
    val fontIndex: Int,
    val visualOrder: Int,
    val estimatedAdvance: Float,
  )

  fun resolve(
    snapshot: PdfExportSnapshot,
    apiLevel: Int = Build.VERSION.SDK_INT,
  ): PdfiumTextSnapshot {
    val fonts = mutableListOf<PdfiumFontResource>()
    val resourceIndices = mutableMapOf<FontKey, Int>()
    val fontCache = mutableMapOf<FontKey, PdfiumFontResource?>()
    val runs = mutableListOf<PdfiumTextRunEntry>()
    var nextLineId = 0

    snapshot.pages.forEach { page ->
      page.textAnnotations.forEach { annotation ->
        val paint = TextLayoutSpec.createPaint(annotation.fontSize)
        val metrics = paint.fontMetrics
        val lineHeight = metrics.descent - metrics.ascent
        val firstBaseline = annotation.position.y.toFloat() - metrics.ascent
        TextLayoutSpec.explicitLines(annotation.text).forEachIndexed { lineIndex, line ->
          if (line.isEmpty()) return@forEachIndexed
          val lineId = nextLineId++
          if (apiLevel >= Build.VERSION_CODES.S) {
            Api31FontResolver.appendLine(
              pageIndex = page.pageIndex,
              lineId = lineId,
              line = line,
              boundsLeft = annotation.bounds.left.toFloat(),
              boundsRight = annotation.bounds.right.toFloat(),
              baseDirectionRtl = annotation.directionRtl,
              baselineFromTop = firstBaseline + lineIndex * lineHeight,
              fontSize = annotation.fontSize.toFloat(),
              color = annotation.textColor,
              paint = paint,
              fonts = fonts,
              resourceIndices = resourceIndices,
              fontCache = fontCache,
              runs = runs,
            )
          } else {
            runs += PdfiumTextRunEntry(
              pageIndex = page.pageIndex,
              lineId = lineId,
              text = line,
              sourceStart = 0,
              sourceLength = line.length,
              bidiLevel = Bidi(
                line,
                if (annotation.directionRtl) Bidi.DIRECTION_RIGHT_TO_LEFT
                else Bidi.DIRECTION_LEFT_TO_RIGHT,
              ).getLevelAt(0),
              visualOrder = 0,
              baseDirectionRtl = annotation.directionRtl,
              fontIndex = -1,
              boundsLeft = annotation.bounds.left.toFloat(),
              boundsRight = annotation.bounds.right.toFloat(),
              baselineFromTop = firstBaseline + lineIndex * lineHeight,
              fontSize = annotation.fontSize.toFloat(),
              estimatedAdvance = paint.measureText(line),
              color = annotation.textColor,
            )
          }
        }
      }
    }

    return PdfiumTextSnapshot(
      fonts = fonts.map { it.copy(bytes = it.bytes.copyOf()) },
      runs = runs.toList(),
    )
  }

  @androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
  private object Api31FontResolver {
    fun appendLine(
      pageIndex: Int,
      lineId: Int,
      line: String,
      boundsLeft: Float,
      boundsRight: Float,
      baseDirectionRtl: Boolean,
      baselineFromTop: Float,
      fontSize: Float,
      color: Int,
      paint: TextPaint,
      fonts: MutableList<PdfiumFontResource>,
      resourceIndices: MutableMap<FontKey, Int>,
      fontCache: MutableMap<FontKey, PdfiumFontResource?>,
      runs: MutableList<PdfiumTextRunEntry>,
    ) {
      val bidi = Bidi(
        line,
        if (baseDirectionRtl) Bidi.DIRECTION_RIGHT_TO_LEFT
        else Bidi.DIRECTION_LEFT_TO_RIGHT,
      )
      val units = mutableListOf<SourceUnit>()
      var sourceIndex = 0
      while (sourceIndex < line.length) {
        val codePoint = line.codePointAt(sourceIndex)
        val sourceEnd = sourceIndex + Character.charCount(codePoint)
        val level = bidi.getLevelAt(sourceIndex)
        val shaped = TextRunShaper.shapeTextRun(
          line,
          sourceIndex,
          sourceEnd - sourceIndex,
          0,
          line.length,
          0f,
          0f,
          (level and 1) != 0,
          paint,
        )
        val fontIndex = if (shaped.glyphCount() == 0) -1 else {
          fontResourceIndex(shaped.getFont(0), fonts, resourceIndices, fontCache)
        }
        units += SourceUnit(
          start = sourceIndex,
          end = sourceEnd,
          codePoint = codePoint,
          bidiLevel = level,
          script = Character.UnicodeScript.of(codePoint),
          fontIndex = fontIndex,
        )
        sourceIndex = sourceEnd
      }

      inheritCommonScripts(units)
      inheritWeakFontSelections(units)
      val logicalSegments = mutableListOf<TextSegment>()
      var unitStart = 0
      while (unitStart < units.size) {
        val first = units[unitStart]
        var unitEnd = unitStart + 1
        while (unitEnd < units.size &&
          units[unitEnd].start == units[unitEnd - 1].end &&
          units[unitEnd].bidiLevel == first.bidiLevel &&
          units[unitEnd].script == first.script &&
          units[unitEnd].fontIndex == first.fontIndex
        ) unitEnd += 1
        val sourceEnd = units[unitEnd - 1].end
        logicalSegments += TextSegment(
          sourceStart = first.start,
          sourceLength = sourceEnd - first.start,
          bidiLevel = first.bidiLevel,
          script = first.script,
          fontIndex = first.fontIndex,
          visualOrder = -1,
          estimatedAdvance = paint.measureText(line, first.start, sourceEnd),
        )
        unitStart = unitEnd
      }

      val visualSegments: Array<Any> = logicalSegments.map { it as Any }.toTypedArray()
      val levels = ByteArray(logicalSegments.size) { logicalSegments[it].bidiLevel.toByte() }
      Bidi.reorderVisually(levels, 0, visualSegments, 0, visualSegments.size)
      val visualOrderByStart = visualSegments.mapIndexed { index, segment ->
        (segment as TextSegment).sourceStart to index
      }.toMap()
      logicalSegments.forEach { segment ->
        runs += PdfiumTextRunEntry(
          pageIndex = pageIndex,
          lineId = lineId,
          text = line,
          sourceStart = segment.sourceStart,
          sourceLength = segment.sourceLength,
          bidiLevel = segment.bidiLevel,
          visualOrder = visualOrderByStart.getValue(segment.sourceStart),
          fontIndex = segment.fontIndex,
          baseDirectionRtl = baseDirectionRtl,
          boundsLeft = boundsLeft,
          boundsRight = boundsRight,
          baselineFromTop = baselineFromTop,
          fontSize = fontSize,
          estimatedAdvance = segment.estimatedAdvance,
          color = color,
        )
      }
    }

    private fun inheritCommonScripts(units: MutableList<SourceUnit>) {
      for (index in units.indices) {
        if (!isWeakScript(units[index].script)) continue
        val previous = (index - 1 downTo 0).firstOrNull {
          units[it].bidiLevel == units[index].bidiLevel && !isWeakScript(units[it].script)
        }
        val next = (index + 1 until units.size).firstOrNull {
          units[it].bidiLevel == units[index].bidiLevel && !isWeakScript(units[it].script)
        }
        units[index] = units[index].copy(script = previous?.let { units[it].script }
          ?: next?.let { units[it].script } ?: Character.UnicodeScript.COMMON)
      }
    }

    private fun inheritWeakFontSelections(units: MutableList<SourceUnit>) {
      for (index in units.indices) {
        if (!isWeakScript(Character.UnicodeScript.of(units[index].codePoint)) &&
          Character.getType(units[index].codePoint) !in setOf(
            Character.NON_SPACING_MARK.toInt(),
            Character.COMBINING_SPACING_MARK.toInt(),
            Character.ENCLOSING_MARK.toInt(),
          )
        ) continue
        val previous = (index - 1 downTo 0).firstOrNull {
          units[it].bidiLevel == units[index].bidiLevel && units[it].fontIndex >= 0
        }
        val next = (index + 1 until units.size).firstOrNull {
          units[it].bidiLevel == units[index].bidiLevel && units[it].fontIndex >= 0
        }
        val inherited = previous?.let { units[it].fontIndex } ?: next?.let { units[it].fontIndex }
        if (inherited != null) units[index] = units[index].copy(fontIndex = inherited)
      }
    }

    private fun isWeakScript(script: Character.UnicodeScript) =
      script == Character.UnicodeScript.COMMON ||
        script == Character.UnicodeScript.INHERITED ||
        script == Character.UnicodeScript.UNKNOWN

    private fun fontResourceIndex(
      font: Font,
      fonts: MutableList<PdfiumFontResource>,
      resourceIndices: MutableMap<FontKey, Int>,
      fontCache: MutableMap<FontKey, PdfiumFontResource?>,
    ): Int {
      val key = FontKey(font.sourceIdentifier, font.ttcIndex)
      val existing = resourceIndices[key]
      if (existing != null) return existing
      if (!fontCache.containsKey(key)) {
        fontCache[key] = try {
          prepareFont(font)
        } catch (_: RuntimeException) {
          null
        }
      }
      val resource = fontCache[key] ?: return -1
      val index = fonts.size
      fonts += resource
      resourceIndices[key] = index
      return index
    }

    private fun prepareFont(font: Font): PdfiumFontResource? {
      if (font.ttcIndex != 0) return null
      val buffer: ByteBuffer = font.buffer.duplicate()
      if (!buffer.hasRemaining()) return null
      val bytes = ByteArray(buffer.remaining()).also(buffer::get)
      if (bytes.size >= 4 && bytes.copyOfRange(0, 4)
          .contentEquals(byteArrayOf(0x74, 0x74, 0x63, 0x66))
      ) return null
      val fsType = readOpenTypeFsType(bytes, font.ttcIndex) ?: return null
      val permission = fsType and 0x000E
      val embeddingAllowed = (permission == 0 || permission == 0x0008) &&
        fsType and 0x0200 == 0 && fsType and 0x0100 == 0
      if (!embeddingAllowed) return null
      return PdfiumFontResource(bytes, font.ttcIndex, fsType)
    }

    private fun readOpenTypeFsType(bytes: ByteArray, collectionIndex: Int): Int? {
      return try {
        if (bytes.size < 12) return null
        val isCollection = bytes.copyOfRange(0, 4)
          .contentEquals(byteArrayOf(0x74, 0x74, 0x63, 0x66))
        val fontOffset = if (isCollection) {
          readU32(bytes, 12 + collectionIndex * 4).toInt()
        } else {
          if (collectionIndex != 0) return null
          0
        }
        val tableCount = readU16(bytes, fontOffset + 4)
        for (index in 0 until tableCount) {
          val record = fontOffset + 12 + index * 16
          if (record + 16 > bytes.size) return null
          if (bytes.copyOfRange(record, record + 4)
              .contentEquals(byteArrayOf(0x4F, 0x53, 0x2F, 0x32))
          ) {
            val tableOffset = readU32(bytes, record + 8).toInt()
            if (tableOffset + 10 > bytes.size) return null
            return readU16(bytes, tableOffset + 8)
          }
        }
        null
      } catch (_: IndexOutOfBoundsException) {
        null
      }
    }

    private fun readU16(bytes: ByteArray, offset: Int): Int =
      ((bytes[offset].toInt() and 0xFF) shl 8) or (bytes[offset + 1].toInt() and 0xFF)

    private fun readU32(bytes: ByteArray, offset: Int): Long =
      ((bytes[offset].toLong() and 0xFF) shl 24) or
        ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
        ((bytes[offset + 2].toLong() and 0xFF) shl 8) or
        (bytes[offset + 3].toLong() and 0xFF)
  }
}

private fun ensureExportFresh(isStale: () -> Boolean, generation: Long) {
  if (isStale()) {
    throw PdfSessionException(
      "operation_cancelled",
      "PDF export generation $generation was superseded",
    )
  }
}

private fun exportFailed(message: String, cause: Throwable? = null) =
  PdfSessionException("pdf_export_failed", message, cause)
