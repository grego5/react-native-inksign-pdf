package com.margelo.nitro.inksignpdf

import android.graphics.Paint
import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

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
  val unicodeFonts: PdfExportFontData? = null,
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
      InkPerfetto.section("InkSign/export PDFium write and validate") {
        PdfiumNativePdfExporter.export(snapshot, candidate)
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

internal data class PdfiumTextEntry(
  val pageIndex: Int,
  val text: String,
  /** 0 = Helvetica, 1 = Noto Sans Hebrew, 2 = Noto Naskh Arabic. */
  val fontKind: Int,
  val x: Float,
  val baselineFromTop: Float,
  val fontSize: Float,
  val color: Int,
)

private data class ExportTextRun(val text: String, val fontKind: Int, val width: Float)

internal fun unicodeTextEntries(snapshot: PdfExportSnapshot): List<PdfiumTextEntry> =
  snapshot.pages.flatMap { page ->
    page.textAnnotations.flatMap { annotation ->
      val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = annotation.fontSize.toFloat()
        typeface = TextLayoutSpec.typeface
      }
      val metrics = paint.fontMetrics
      val lineHeight = metrics.descent - metrics.ascent
      val firstBaseline = annotation.position.y.toFloat() - metrics.ascent
      TextLayoutSpec.explicitLines(annotation.text).flatMapIndexed { lineIndex, line ->
        if (line.isEmpty()) return@flatMapIndexed emptyList()
        val runs = exportTextRuns(line, paint)
        val isRtl = textIsRtl(line)
        var cursor = if (isRtl) {
          annotation.position.x.toFloat() + runs.sumOf { it.width.toDouble() }.toFloat()
        } else {
          annotation.position.x.toFloat()
        }
        runs.map { run ->
          val x = if (isRtl) {
            cursor -= run.width
            cursor
          } else {
            val start = cursor
            cursor += run.width
            start
          }
          PdfiumTextEntry(
            pageIndex = page.pageIndex,
            text = run.text,
            fontKind = run.fontKind,
            x = x,
            baselineFromTop = firstBaseline + lineIndex * lineHeight,
            fontSize = annotation.fontSize.toFloat(),
            color = annotation.textColor,
          )
        }
      }
    }
  }

private fun exportTextRuns(line: String, paint: Paint): List<ExportTextRun> {
  data class Character(val value: String, val fontKind: Int?)
  val characters = buildList {
    var index = 0
    while (index < line.length) {
      val codePoint = line.codePointAt(index)
      val next = index + java.lang.Character.charCount(codePoint)
      add(Character(line.substring(index, next), exportFontKind(codePoint)))
      index = next
    }
  }
  val assigned = characters.mapIndexed { index, character ->
    character.fontKind
      ?: characters.subList(0, index).lastOrNull { it.fontKind != null }?.fontKind
      ?: characters.drop(index + 1).firstOrNull { it.fontKind != null }?.fontKind
      ?: 0
  }
  val result = mutableListOf<ExportTextRun>()
  var start = 0
  while (start < characters.size) {
    val fontKind = assigned[start]
    var end = start + 1
    while (end < characters.size && assigned[end] == fontKind) end += 1
    val text = characters.subList(start, end).joinToString(separator = "") { it.value }
    result += ExportTextRun(text, fontKind, paint.measureText(text))
    start = end
  }
  return result
}

private fun exportFontKind(codePoint: Int): Int? = when {
  codePoint in 0x0590..0x05FF || codePoint in 0xFB1D..0xFB4F -> 1
  codePoint in 0x0600..0x06FF || codePoint in 0x0750..0x077F ||
    codePoint in 0x08A0..0x08FF || codePoint in 0xFB50..0xFDFF ||
    codePoint in 0xFE70..0xFEFF -> 2
  java.lang.Character.isWhitespace(codePoint) ||
    java.lang.Character.getType(codePoint) in setOf(
      java.lang.Character.CONNECTOR_PUNCTUATION.toInt(),
      java.lang.Character.DASH_PUNCTUATION.toInt(),
      java.lang.Character.START_PUNCTUATION.toInt(),
      java.lang.Character.END_PUNCTUATION.toInt(),
      java.lang.Character.OTHER_PUNCTUATION.toInt(),
      java.lang.Character.MATH_SYMBOL.toInt(),
    ) -> null
  else -> 0
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
