package com.margelo.nitro.inksignpdf

import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.pdf.PdfRendererPreV
import android.graphics.pdf.component.PdfPagePathObject
import android.graphics.pdf.component.PdfPageTextObject
import android.graphics.pdf.component.PdfPageTextObjectFont
import android.os.ParcelFileDescriptor
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
) {
    init {
        require(pages.isNotEmpty())
        require(pages.mapIndexed { index, page -> index == page.pageIndex }.all { it })
    }
}

private data class PdfPageExportExpectation(
  val pageIndex: Int,
  val expectedPathCount: Int,
  val expectedInkPathCount: Int,
  val sourceTextObjectCount: Int,
  val expectedTextObjectCount: Int,
)

/** Adds final page-space outlines to a separate PdfRendererPreV session. */
internal object PdfExporter {
    fun export(
        snapshot: PdfExportSnapshot,
        artifactPolicy: CacheArtifactPolicy,
        isStale: () -> Boolean,
    ): String {
        PdfApiSupport.requireSupported()
        ensureExportFresh(isStale, snapshot.generation)

        val source = File(snapshot.sourcePath)
        val output = artifactPolicy.validatedSignedOutput(snapshot.outputPath, source)
        var temporary: File? = null
        try {
            if (!source.isFile || !source.canRead()) {
                throw exportFailed("The opened source PDF is no longer readable")
            }

            val temporaryFile = artifactPolicy.allocateExportScratch()
            temporary = temporaryFile
            val expectedPaths = InkPerfetto.section("InkSign/export add paths") {
                PdfExportSession.open(source).use { session ->
                    val expected = session.addStrokes(snapshot, isStale)
                    InkPerfetto.section("InkSign/export write") {
                        session.write(temporaryFile, snapshot.generation, isStale)
                    }
                    expected
                }
            }

            ensureExportFresh(isStale, snapshot.generation)
            InkPerfetto.section("InkSign/export validate") {
                validate(temporaryFile, snapshot, expectedPaths, isStale)
            }
            ensureExportFresh(isStale, snapshot.generation)
            moveAtomically(temporaryFile, output)
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

    private fun validate(
        output: File,
        snapshot: PdfExportSnapshot,
        expectedPaths: List<PdfPageExportExpectation>,
        isStale: () -> Boolean,
    ) {
        ensureExportFresh(isStale, snapshot.generation)
        PdfExportSession.open(output).use { session ->
            if (session.renderer.pageCount != snapshot.pages.size) {
                throw exportFailed("The rewritten PDF page count does not match the source")
            }
            expectedPaths.forEach { expected ->
                ensureExportFresh(isStale, snapshot.generation)
                session.renderer.openPage(expected.pageIndex).use { page ->
                    val captured = snapshot.pages[expected.pageIndex]
                    if (page.width.toDouble() != captured.dimensions.width ||
                        page.height.toDouble() != captured.dimensions.height
                    ) {
                        throw exportFailed("The rewritten PDF dimensions do not match the source page")
                    }

                    var pathCount = 0
                    var matchingInkCount = 0
                    page.getPageObjects().forEach { pageObjectEntry ->
                        val pageObject = pageObjectEntry.second
                        if (pageObject is PdfPagePathObject) {
                            pathCount += 1
                            if (pageObject.renderMode == PdfPagePathObject.RENDER_MODE_FILL &&
                                pageObject.fillColor == snapshot.color
                            ) {
                                matchingInkCount += 1
                            }
                        }
                    }
                    if (pathCount < expected.expectedPathCount) {
                        throw exportFailed("The rewritten PDF lost vector path objects")
                    }
                    if (matchingInkCount < expected.expectedInkPathCount) {
                        throw exportFailed("The rewritten PDF does not contain the page ink paths")
                    }
                    val textObjectCount = page.getPageObjects()
                        .count { it.second is PdfPageTextObject }
                    if (textObjectCount != expected.expectedTextObjectCount) {
                        throw exportFailed(
                            "The rewritten PDF text-object count changed from " +
                                "${expected.sourceTextObjectCount} source objects plus " +
                                "${expected.expectedTextObjectCount - expected.sourceTextObjectCount} " +
                                "annotation objects to $textObjectCount",
                        )
                    }
                }
            }
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

/** A short-lived, worker-owned renderer used only for one export. */
private class PdfExportSession private constructor(
    private val sourceDescriptor: ParcelFileDescriptor,
    val renderer: PdfRendererPreV,
) : AutoCloseable {
    private var closed = false

    fun addStrokes(
        snapshot: PdfExportSnapshot,
        isStale: () -> Boolean,
    ): List<PdfPageExportExpectation> {
        check(!closed)
        ensureExportFresh(isStale, snapshot.generation)
        if (renderer.pageCount != snapshot.pages.size) {
            throw exportFailed("The source PDF page count does not match the captured document")
        }
        return snapshot.pages.map { captured ->
            ensureExportFresh(isStale, snapshot.generation)
            if (captured.pageIndex !in 0 until renderer.pageCount) {
                throw exportFailed("The captured PDF page index is invalid")
            }
            renderer.openPage(captured.pageIndex).use { page ->
                if (page.width <= 0 || page.height <= 0 ||
                    page.width.toDouble() != captured.dimensions.width ||
                    page.height.toDouble() != captured.dimensions.height
                ) {
                    throw exportFailed("The source PDF page dimensions changed")
                }
                var expectedPathCount = page.getPageObjects()
                    .count { it.second is PdfPagePathObject }
                var expectedInkPathCount = 0
                captured.strokes.forEach { stroke ->
                    stroke.contourPathData.forEach { pathData ->
                        ensureExportFresh(isStale, snapshot.generation)
                        val pathObject = PdfPagePathObject(pathData.toPdfExportPath()).apply {
                            setMatrix(pdfPathCoordinateInverseScale())
                            setRenderMode(PdfPagePathObject.RENDER_MODE_FILL)
                            setFillColor(snapshot.color)
                        }
                        if (page.addPageObject(pathObject) < 0) {
                            throw PdfSessionException(
                                "pdf_export_failed",
                                "Unable to add a vector ink path",
                            )
                        }
                        expectedPathCount += 1
                        expectedInkPathCount += 1
                    }
                }
                val sourceTextObjectCount = page.getPageObjects()
                    .count { it.second is PdfPageTextObject }
                var expectedTextObjectCount = sourceTextObjectCount
                captured.textAnnotations.forEach { annotation ->
                    textObjectsForExport(annotation, annotation.textColor).forEach { textObject ->
                        ensureExportFresh(isStale, snapshot.generation)
                        if (page.addPageObject(textObject) < 0) {
                            throw PdfSessionException(
                                "pdf_export_failed",
                                "Unable to add a text object",
                            )
                        }
                        expectedTextObjectCount += 1
                    }
                }
                PdfPageExportExpectation(
                    pageIndex = captured.pageIndex,
                    expectedPathCount = expectedPathCount,
                    expectedInkPathCount = expectedInkPathCount,
                    sourceTextObjectCount = sourceTextObjectCount,
                    expectedTextObjectCount = expectedTextObjectCount,
                )
            }
        }
    }

    fun write(
        temporary: File,
        generation: Long,
        isStale: () -> Boolean,
    ) {
        check(!closed)
        ensureExportFresh(isStale, generation)
        val destination = try {
            ParcelFileDescriptor.open(
                temporary,
                ParcelFileDescriptor.MODE_WRITE_ONLY or
                        ParcelFileDescriptor.MODE_CREATE or
                        ParcelFileDescriptor.MODE_TRUNCATE,
            )
        } catch (error: IOException) {
            throw PdfSessionException(
                "pdf_export_failed",
                "Unable to create the temporary PDF",
                error,
            )
        }
        try {
            renderer.write(destination, false)
        } finally {
            destination.close()
        }
        ensureExportFresh(isStale, generation)
    }

    override fun close() {
        if (closed) return
        closed = true
        try {
            renderer.close()
        } finally {
            sourceDescriptor.close()
        }
    }

    companion object {
        fun open(source: File): PdfExportSession {
            val descriptor = try {
                ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
            } catch (error: IOException) {
                throw PdfSessionException(
                    "pdf_export_failed",
                    "Unable to open the source PDF for export",
                    error,
                )
            } catch (error: SecurityException) {
                throw PdfSessionException(
                    "pdf_export_failed",
                    "Unable to open the source PDF for export",
                    error,
                )
            }

            var renderer: PdfRendererPreV? = null
            try {
                val openedRenderer = PdfRendererPreV(descriptor)
                renderer = openedRenderer
                if (openedRenderer.pageCount <= 0) {
                    throw exportFailed("The source PDF has no pages")
                }
                return PdfExportSession(descriptor, openedRenderer)
            } catch (error: PdfSessionException) {
                closeFailedPdfResources(renderer, descriptor)
                throw error
            } catch (error: Throwable) {
                closeFailedPdfResources(renderer, descriptor)
                throw exportFailed("Unable to open the source PDF for export", error)
            }
        }

    }
}

private const val PDF_PATH_COORDINATE_SCALE = 256f

private fun InkPathData.toPdfExportPath() = toPath().apply {
    transform(Matrix().apply {
        setScale(PDF_PATH_COORDINATE_SCALE, PDF_PATH_COORDINATE_SCALE)
    })
}

private fun textObjectsForExport(
    annotation: TextAnnotation,
    color: Int,
): List<PdfPageTextObject> {
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = annotation.fontSize.toFloat()
    }
    val metrics = paint.fontMetrics
    val lineHeight = metrics.descent - metrics.ascent
    val firstBaseline = annotation.position.y.toFloat() - metrics.ascent
    val font = PdfPageTextObjectFont(
        PdfPageTextObjectFont.FONT_FAMILY_HELVETICA,
        false,
        false,
    )
    return TextLayoutSpec.explicitLines(annotation.text)
        .mapIndexedNotNull { index, line ->
            if (line.isEmpty()) return@mapIndexedNotNull null
            PdfPageTextObject(line, font, annotation.fontSize.toFloat()).apply {
                setRenderMode(PdfPageTextObject.RENDER_MODE_FILL)
                setFillColor(color)
                setMatrix(Matrix().apply {
                    setTranslate(
                        annotation.position.x.toFloat(),
                        firstBaseline + index * lineHeight,
                    )
                })
            }
        }
}

private fun pdfPathCoordinateInverseScale() = Matrix().apply {
    setScale(1f / PDF_PATH_COORDINATE_SCALE, 1f / PDF_PATH_COORDINATE_SCALE)
}

private fun ensureExportFresh(isStale: () -> Boolean, generation: Long) {
    if (isStale()) {
        throw PdfSessionException(
            "operation_cancelled",
            "PDF export generation $generation was superseded",
        )
    }
}

private fun invalidOutputPath(
    message: String,
    cause: Throwable? = null,
): PdfSessionException {
    return PdfSessionException("invalid_output_path", message, cause)
}

private fun exportFailed(
    message: String,
    cause: Throwable? = null,
): PdfSessionException {
    return PdfSessionException("pdf_export_failed", message, cause)
}
