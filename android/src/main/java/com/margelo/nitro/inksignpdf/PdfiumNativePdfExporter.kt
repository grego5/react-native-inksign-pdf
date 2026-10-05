package com.margelo.nitro.inksignpdf

import java.io.File

/** Serializes resolved PDFium text runs and validates the saved candidate. */
internal object PdfiumNativePdfExporter {
  fun export(snapshot: PdfExportSnapshot, text: PdfiumTextSnapshot, destination: File) =
    exportInternal(snapshot, text, destination, forceSubsetSaveFailureForTesting = false)

  internal fun exportForTesting(
    snapshot: PdfExportSnapshot,
    text: PdfiumTextSnapshot,
    destination: File,
    forceSubsetSaveFailure: Boolean,
  ) = exportInternal(snapshot, text, destination, forceSubsetSaveFailure)

  private fun exportInternal(
    snapshot: PdfExportSnapshot,
    text: PdfiumTextSnapshot,
    destination: File,
    forceSubsetSaveFailureForTesting: Boolean,
  ) {
    val pageIndices = IntArray(snapshot.pages.size) { snapshot.pages[it].pageIndex }
    val pageRotations = IntArray(snapshot.pages.size) { snapshot.pages[it].dimensions.rotation }
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

    val textRuns = text.runs
    val textRunPageIndices = IntArray(textRuns.size) { textRuns[it].pageIndex }
    val textRunLineIds = IntArray(textRuns.size) { textRuns[it].lineId }
    val textRunTexts = Array(textRuns.size) { textRuns[it].text }
    val textRunSourceRanges = IntArray(textRuns.size * 2) { index ->
      val run = textRuns[index / 2]
      if (index % 2 == 0) run.sourceStart else run.sourceLength
    }
    val textRunBidiLevels = IntArray(textRuns.size) { textRuns[it].bidiLevel }
    val textRunVisualOrder = IntArray(textRuns.size) { textRuns[it].visualOrder }
    val textRunBaseDirections = IntArray(textRuns.size) {
      if (textRuns[it].baseDirectionRtl) 1 else 0
    }
    val textRunAlignments = IntArray(textRuns.size) { textRuns[it].textAlignment }
    val textRunFontIndices = IntArray(textRuns.size) { textRuns[it].fontIndex }
    val textRunGeometry = FloatArray(textRuns.size * 5) { index ->
      val run = textRuns[index / 5]
      when (index % 5) {
        0 -> run.boundsLeft
        1 -> run.boundsRight
        2 -> run.baselineFromTop
        3 -> run.fontSize
        else -> run.estimatedAdvance
      }
    }
    val textRunColors = IntArray(textRuns.size) { textRuns[it].color }
    val textRunTransforms = FloatArray(textRuns.size * 6) { index ->
      val transform = textRuns[index / 6].layoutToRaw
      when (index % 6) {
        0 -> transform.a.toFloat()
        1 -> transform.b.toFloat()
        2 -> transform.c.toFloat()
        3 -> transform.d.toFloat()
        4 -> transform.tx.toFloat()
        else -> transform.ty.toFloat()
      }
    }
    val fontResources = Array(text.fonts.size) { text.fonts[it].bytes.copyOf() }
    val maySubsetFonts = text.fonts.all { it.fsType and 0x0100 == 0 }

    nativeExport(
      snapshot.sourcePath,
      destination.path,
      pageIndices,
      pageDimensions,
      pageRotations,
      pathPageIndices,
      pathCommandOffsets,
      pathCommandTypes,
      pathCoordinates,
      textRunPageIndices,
      textRunLineIds,
      textRunTexts,
      textRunSourceRanges,
      textRunBidiLevels,
      textRunVisualOrder,
      textRunBaseDirections,
      textRunAlignments,
      textRunFontIndices,
      textRunGeometry,
      textRunColors,
      textRunTransforms,
      fontResources,
      maySubsetFonts,
      forceSubsetSaveFailureForTesting,
      snapshot.color,
    )
  }

  private external fun nativeExport(
    sourcePath: String,
    destinationPath: String,
    pageIndices: IntArray,
    pageDimensions: DoubleArray,
    pageRotations: IntArray,
    pathPageIndices: IntArray,
    pathCommandOffsets: IntArray,
    pathCommandTypes: IntArray,
    pathCoordinates: FloatArray,
    textRunPageIndices: IntArray,
    textRunLineIds: IntArray,
    textRunTexts: Array<String>,
    textRunSourceRanges: IntArray,
    textRunBidiLevels: IntArray,
    textRunVisualOrder: IntArray,
    textRunBaseDirections: IntArray,
    textRunAlignments: IntArray,
    textRunFontIndices: IntArray,
    textRunGeometry: FloatArray,
    textRunColors: IntArray,
    textRunTransforms: FloatArray,
    fontResources: Array<ByteArray>,
    maySubsetFonts: Boolean,
    forceSubsetSaveFailureForTesting: Boolean,
    inkColor: Int,
  )
}
