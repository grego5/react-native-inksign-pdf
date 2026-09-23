package com.margelo.nitro.inksignpdf

import android.content.Context
import java.io.File

internal data class PdfExportFontData(
  val hebrew: ByteArray,
  val arabic: ByteArray,
)

internal object PdfExportFonts {
  fun load(context: Context): PdfExportFontData {
    fun readAsset(name: String): ByteArray =
      context.assets.open("fonts/$name").use { it.readBytes() }

    return PdfExportFontData(
      hebrew = readAsset("NotoSansHebrew-Regular.ttf"),
      arabic = readAsset("NotoNaskhArabic-Regular.ttf"),
    )
  }
}

/** Serializes all exported PDF page objects and validates the saved candidate in PDFium. */
internal object PdfiumNativePdfExporter {
  fun export(snapshot: PdfExportSnapshot, destination: File) {
    val pageIndices = IntArray(snapshot.pages.size) { snapshot.pages[it].pageIndex }
    val pageDimensions = DoubleArray(snapshot.pages.size * 2) { index ->
      val page = snapshot.pages[index / 2]
      if (index % 2 == 0) page.dimensions.width else page.dimensions.height
    }
    val paths = snapshot.pages.flatMap { page ->
      page.strokes.flatMap { stroke -> stroke.contourPathData.map { page.pageIndex to it } }
    }
    val pathPageIndices = IntArray(paths.size) { paths[it].first }
    val pathCommandOffsets = IntArray(paths.size + 1)
    val pathCommands = paths.flatMap { it.second.commands }
    var commandOffset = 0
    paths.indices.forEach { index ->
      pathCommandOffsets[index] = commandOffset
      commandOffset += paths[index].second.commands.size
    }
    pathCommandOffsets[paths.size] = commandOffset
    val pathCommandTypes = IntArray(pathCommands.size) { pathCommands[it].type }
    val pathCoordinates = FloatArray(pathCommands.size * 6) { index ->
      val command = pathCommands[index / 6]
      when (index % 6) {
        0 -> command.x
        1 -> command.y
        2 -> command.c1x
        3 -> command.c1y
        4 -> command.c2x
        else -> command.c2y
      }
    }
    val textEntries = unicodeTextEntries(snapshot)
    val textPageIndices = IntArray(textEntries.size) { textEntries[it].pageIndex }
    val texts = Array(textEntries.size) { textEntries[it].text }
    val textFontKinds = IntArray(textEntries.size) { textEntries[it].fontKind }
    val textGeometry = FloatArray(textEntries.size * 3) { index ->
      val entry = textEntries[index / 3]
      when (index % 3) {
        0 -> entry.x
        1 -> entry.baselineFromTop
        else -> entry.fontSize
      }
    }
    val textColors = IntArray(textEntries.size) { textEntries[it].color }
    val needsHebrew = textFontKinds.any { it == 1 }
    val needsArabic = textFontKinds.any { it == 2 }
    val fonts = snapshot.unicodeFonts
    check(!needsHebrew || fonts?.hebrew?.isNotEmpty() == true) {
      "Hebrew export font is unavailable"
    }
    check(!needsArabic || fonts?.arabic?.isNotEmpty() == true) {
      "Arabic export font is unavailable"
    }

    nativeExport(
      snapshot.sourcePath,
      destination.path,
      pageIndices,
      pageDimensions,
      pathPageIndices,
      pathCommandOffsets,
      pathCommandTypes,
      pathCoordinates,
      textPageIndices,
      texts,
      textFontKinds,
      textGeometry,
      textColors,
      snapshot.color,
      fonts?.hebrew ?: ByteArray(0),
      fonts?.arabic ?: ByteArray(0),
    )
  }

  private external fun nativeExport(
    sourcePath: String,
    destinationPath: String,
    pageIndices: IntArray,
    pageDimensions: DoubleArray,
    pathPageIndices: IntArray,
    pathCommandOffsets: IntArray,
    pathCommandTypes: IntArray,
    pathCoordinates: FloatArray,
    textPageIndices: IntArray,
    texts: Array<String>,
    textFontKinds: IntArray,
    textGeometry: FloatArray,
    textColors: IntArray,
    inkColor: Int,
    hebrewFont: ByteArray,
    arabicFont: ByteArray,
  )
}
