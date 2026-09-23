package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.pdf.PdfDocument
import android.graphics.pdf.PdfRendererPreV
import android.graphics.pdf.RenderParams
import android.graphics.pdf.component.PdfPagePathObject
import android.graphics.pdf.component.PdfPageTextObject
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.ext.SdkExtensions
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class PdfExportContourTest {
    @Test
    fun exporterWritesIndependentFilledContourObjectsAndRasterizedOverlap() {
        assumeTrue(
            "PdfRendererPreV requires Android S extension 18",
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 18,
        )
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .targetContext
        val policy = CacheArtifactPolicy.initialize(context)
        val source = File.createTempFile("ink-contour-source-", ".pdf", context.cacheDir)
        val output = policy.allocateSignedOutput()
        try {
            writeBlankPdf(source)
            val outline = StrokeOutline.copyOf(overlappingOppositeContours())
            val snapshot = PdfExportSnapshot(
                sourcePath = source.path,
                outputPath = output.path,
                pages = listOf(
                    PdfPageExportSnapshot(
                        pageIndex = 0,
                        dimensions = PdfPageDimensions(50.0, 50.0),
                        strokes = listOf(outline),
                    ),
                ),
                generation = 1L,
                color = Color.BLACK,
            )

            PdfExporter.export(snapshot, policy) { false }
            assertTrue(source.isFile)
            PdfExporter.export(snapshot, policy) { false }
            assertTrue(source.isFile)

            val sourcePathCount = countPathObjects(source)
            val outputPathCount = countPathObjects(output)
            assertEquals(sourcePathCount + outline.contourPathData.size, outputPathCount)

            val bitmap = Bitmap.createBitmap(50, 50, Bitmap.Config.ARGB_8888)
            try {
                renderPage(output, bitmap)
                assertEquals(Color.BLACK, bitmap.getPixel(20, 20))
            } finally {
                bitmap.recycle()
            }
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    @Test
    fun exporterPreservesFractionalContourCoordinatesInSavedGeometry() {
        assumeTrue(
            "PdfRendererPreV requires Android S extension 18",
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 18,
        )
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .targetContext
        val policy = CacheArtifactPolicy.initialize(context)
        val source = File.createTempFile("ink-fractional-source-", ".pdf", context.cacheDir)
        val output = policy.allocateSignedOutput()
        try {
            writeBlankPdf(source)
            val snapshot = PdfExportSnapshot(
                sourcePath = source.path,
                outputPath = output.path,
                pages = listOf(
                    PdfPageExportSnapshot(
                        pageIndex = 0,
                        dimensions = PdfPageDimensions(50.0, 50.0),
                        strokes = listOf(StrokeOutline.fromCommands(listOf(
                            InkPathCommand(InkPathCommand.MOVE, 10.125f, 11.375f),
                            InkPathCommand(InkPathCommand.LINE, 30.625f, 11.375f),
                            InkPathCommand(InkPathCommand.LINE, 20.25f, 31.875f),
                            InkPathCommand(InkPathCommand.CLOSE),
                        ))),
                    ),
                ),
                generation = 1L,
                color = Color.BLACK,
            )

            PdfExporter.export(snapshot, policy) { false }

            val savedPath = savedInkPath(output)
            assertPathContainsPoint(savedPath, 10.125f, 11.375f)
            assertPathContainsPoint(savedPath, 30.625f, 11.375f)
            assertPathContainsPoint(savedPath, 20.25f, 31.875f)
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    @Test
    fun exporterPreservesEveryPageAndPlacesInkOnMatchingPages() {
        assumeTrue(
            "PdfRendererPreV requires Android S extension 18",
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 18,
        )
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .targetContext
        val policy = CacheArtifactPolicy.initialize(context)
        val source = File.createTempFile("ink-multi-page-source-", ".pdf", context.cacheDir)
        val output = policy.allocateSignedOutput()
        try {
            val pageSizes = listOf(50 to 50, 70 to 40, 60 to 60)
            writeBlankPdf(source, pageSizes)
            val pageZeroStroke = StrokeOutline.fromCommands(listOf(
                InkPathCommand(InkPathCommand.MOVE, 8.5f, 9.5f),
                InkPathCommand(InkPathCommand.LINE, 25.5f, 9.5f),
                InkPathCommand(InkPathCommand.LINE, 16.5f, 24.5f),
                InkPathCommand(InkPathCommand.CLOSE),
            ))
            val pageOneStroke = StrokeOutline.fromCommands(listOf(
                InkPathCommand(InkPathCommand.MOVE, 12.25f, 13.75f),
                InkPathCommand(InkPathCommand.LINE, 32.75f, 13.75f),
                InkPathCommand(InkPathCommand.LINE, 22.5f, 30.25f),
                InkPathCommand(InkPathCommand.CLOSE),
            ))
            val snapshot = PdfExportSnapshot(
                sourcePath = source.path,
                outputPath = output.path,
                pages = listOf(
                    PdfPageExportSnapshot(
                        pageIndex = 0,
                        dimensions = PdfPageDimensions(50.0, 50.0),
                        strokes = listOf(pageZeroStroke),
                    ),
                    PdfPageExportSnapshot(
                        pageIndex = 1,
                        dimensions = PdfPageDimensions(70.0, 40.0),
                        strokes = listOf(pageOneStroke),
                    ),
                    PdfPageExportSnapshot(
                        pageIndex = 2,
                        dimensions = PdfPageDimensions(60.0, 60.0),
                        strokes = emptyList(),
                    ),
                ),
                generation = 1L,
                color = Color.BLACK,
            )

            PdfExporter.export(snapshot, policy) { false }

            ParcelFileDescriptor.open(output, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRendererPreV(descriptor).use { renderer ->
                    assertEquals(3, renderer.pageCount)
                    pageSizes.forEachIndexed { pageIndex, size ->
                        renderer.openPage(pageIndex).use { page ->
                            assertEquals(size.first.toDouble(), page.width.toDouble(), 0.0)
                            assertEquals(size.second.toDouble(), page.height.toDouble(), 0.0)
                        }
                    }
                }
            }
            assertEquals(1, countPathObjects(output, pageIndex = 0))
            assertEquals(1, countPathObjects(output, pageIndex = 1))
            assertEquals(0, countPathObjects(output, pageIndex = 2))
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    @Test
    fun exporterWritesUnicodeTextObjectsWithExplicitLinePlacement() {
        assumeTrue(
            "PdfRendererPreV requires Android S extension 18",
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 18,
        )
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .targetContext
        val policy = CacheArtifactPolicy.initialize(context)
        val source = File.createTempFile("text-export-source-", ".pdf", context.cacheDir)
        val output = policy.allocateSignedOutput()
        try {
            writeBlankPdf(source, listOf(240 to 160))
            val annotation = TextAnnotation(
                id = "text-1",
                text = "Latin\n\nשלום العربية",
                bounds = PageRect(24.0, 32.0, 216.0, 84.0),
                fontSize = 14.0,
            )
            val snapshot = PdfExportSnapshot(
                sourcePath = source.path,
                outputPath = output.path,
                pages = listOf(
                    PdfPageExportSnapshot(
                        pageIndex = 0,
                        dimensions = PdfPageDimensions(240.0, 160.0),
                        strokes = emptyList(),
                        textAnnotations = listOf(annotation),
                    ),
                ),
                generation = 1L,
                color = Color.BLACK,
            )

            PdfExporter.export(snapshot, policy) { false }

            ParcelFileDescriptor.open(output, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRendererPreV(descriptor).use { renderer ->
                    renderer.openPage(0).use { page ->
                        val textObjects = page.getPageObjects()
                            .map { it.second }
                            .filterIsInstance<PdfPageTextObject>()
                        assertEquals(2, textObjects.size)
                        assertEquals(listOf("Latin", "שלום العربية"), textObjects.map { it.text })
                        assertEquals(24.0f, textObjects[0].matrix[2], 0.001f)
                        assertTrue(textObjects[0].matrix[5] > 32.0f)
                        assertTrue(textObjects[1].matrix[5] > textObjects[0].matrix[5])

                        val extractedText = page.getTextContents().joinToString { it.text }
                        assertTrue(extractedText.contains("Latin"))
                        assertTrue(extractedText.contains("שלום"))
                        assertTrue(extractedText.contains("العربية"))

                        val bitmap = Bitmap.createBitmap(240, 160, Bitmap.Config.ARGB_8888)
                        try {
                            renderPage(output, bitmap)
                            val renderedBounds = requireNotNull(darkPixelBounds(bitmap, Rect(0, 20, 240, 100)))
                            assertTrue("Rendered text must reach the canonical top-edge band", renderedBounds.top in 24..40)
                            assertTrue(renderedBounds.bottom > renderedBounds.top + 12)
                            val rtlBounds = requireNotNull(darkPixelBounds(bitmap, Rect(0, 55, 240, 100)))
                            assertTrue("Rendered RTL text must produce pixels in its own line band", rtlBounds.width() > 20)
                            assertTrue("Rendered RTL text must have non-trivial glyph coverage", darkPixelCount(bitmap, Rect(0, 55, 240, 100)) > 30)
                        } finally {
                            bitmap.recycle()
                        }
                    }
                }
            }
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    @Test
    fun exporterCountsExistingSourceTextSeparatelyFromAddedText() {
        assumeTrue(
            "PdfRendererPreV requires Android S extension 18",
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 18,
        )
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .targetContext
        val policy = CacheArtifactPolicy.initialize(context)
        val source = File.createTempFile("source-text-export-", ".pdf", context.cacheDir)
        val output = policy.allocateSignedOutput()
        try {
            writePdfWithTextObject(source, 240, 160, "Source")
            val sourceTextCount = countTextObjects(source)
            assertTrue("The source fixture must expose its text object", sourceTextCount > 0)
            assertEquals(listOf("Source"), textObjectContents(source))
            val annotation = TextAnnotation(
                id = "text-1",
                text = "Added",
                bounds = PageRect(24.0, 32.0, 90.0, 52.0),
                fontSize = 14.0,
            )
            PdfExporter.export(
                PdfExportSnapshot(
                    sourcePath = source.path,
                    outputPath = output.path,
                    pages = listOf(
                        PdfPageExportSnapshot(
                            pageIndex = 0,
                            dimensions = PdfPageDimensions(240.0, 160.0),
                            strokes = emptyList(),
                            textAnnotations = listOf(annotation),
                        ),
                    ),
                    generation = 1L,
                    color = Color.BLACK,
                ),
                policy,
            ) { false }

            assertEquals(sourceTextCount + 1, countTextObjects(output))
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    private fun writeBlankPdf(
        file: File,
        pageSizes: List<Pair<Int, Int>> = listOf(50 to 50),
    ) {
        val document = PdfDocument()
        try {
            pageSizes.forEachIndexed { index, size ->
                val page = document.startPage(
                    PdfDocument.PageInfo.Builder(size.first, size.second, index + 1).create(),
                )
                document.finishPage(page)
            }
            file.outputStream().use(document::writeTo)
        } finally {
            document.close()
        }
    }

    private fun writePdfWithTextObject(file: File, width: Int, height: Int, text: String) {
        val content = "BT /F1 12 Tf 8 140 Td ($text) Tj ET\n"
        val objects = listOf(
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] " +
                "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length ${content.toByteArray(Charsets.ISO_8859_1).size} >>\n" +
                "stream\n$content endstream",
        )
        val pdf = StringBuilder("%PDF-1.4\n")
        val offsets = objects.mapIndexed { index, body ->
            val offset = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
            pdf.append("${index + 1} 0 obj\n$body\nendobj\n")
            offset
        }
        val xrefOffset = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
        pdf.append("xref\n0 ${objects.size + 1}\n0000000000 65535 f \n")
        offsets.forEach { offset -> pdf.append("%010d 00000 n \n".format(offset)) }
        pdf.append("trailer\n<< /Size ${objects.size + 1} /Root 1 0 R >>\nstartxref\n")
        pdf.append(xrefOffset).append("\n%%EOF\n")
        file.writeBytes(pdf.toString().toByteArray(Charsets.ISO_8859_1))
    }

    private fun countPathObjects(file: File, pageIndex: Int = 0): Int {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRendererPreV(descriptor).use { renderer ->
                renderer.openPage(pageIndex).use { page ->
                    return page.getPageObjects().count { it.second is PdfPagePathObject }
                }
            }
        }
    }

    private fun countTextObjects(file: File, pageIndex: Int = 0): Int {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRendererPreV(descriptor).use { renderer ->
                renderer.openPage(pageIndex).use { page ->
                    return page.getPageObjects().count { it.second is PdfPageTextObject }
                }
            }
        }
    }

    private fun textObjectContents(file: File, pageIndex: Int = 0): List<String> {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRendererPreV(descriptor).use { renderer ->
                renderer.openPage(pageIndex).use { page ->
                    return page.getPageObjects()
                        .map { it.second }
                        .filterIsInstance<PdfPageTextObject>()
                        .map { it.text }
                }
            }
        }
    }

    private fun darkPixelBounds(bitmap: Bitmap, region: Rect): Rect? {
        var bounds: Rect? = null
        for (y in region.top.coerceAtLeast(0) until region.bottom.coerceAtMost(bitmap.height)) {
            for (x in region.left.coerceAtLeast(0) until region.right.coerceAtMost(bitmap.width)) {
                val pixel = bitmap.getPixel(x, y)
                if (Color.alpha(pixel) > 0 && Color.red(pixel) < 245) {
                    if (bounds == null) bounds = Rect(x, y, x + 1, y + 1)
                    else bounds?.union(x, y, x + 1, y + 1)
                }
            }
        }
        return bounds
    }

    private fun darkPixelCount(bitmap: Bitmap, region: Rect): Int {
        var count = 0
        for (y in region.top.coerceAtLeast(0) until region.bottom.coerceAtMost(bitmap.height)) {
            for (x in region.left.coerceAtLeast(0) until region.right.coerceAtMost(bitmap.width)) {
                val pixel = bitmap.getPixel(x, y)
                if (Color.alpha(pixel) > 0 && Color.red(pixel) < 245) count += 1
            }
        }
        return count
    }

    private fun savedInkPath(file: File, pageIndex: Int = 0): Path {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRendererPreV(descriptor).use { renderer ->
                renderer.openPage(pageIndex).use { page ->
                    val objectPath = page.getPageObjects()
                        .map { it.second }
                        .filterIsInstance<PdfPagePathObject>()
                        .last()
                    return Path(objectPath.toPath()).apply {
                        transform(Matrix().apply { setValues(objectPath.matrix) })
                    }
                }
            }
        }
    }

    private fun assertPathContainsPoint(path: Path, x: Float, y: Float) {
        val samples = path.approximate(0.01f)
        assertTrue(samples.indices.step(3).any { index ->
            kotlin.math.abs(samples[index + 1] - x) < 0.01f &&
                kotlin.math.abs(samples[index + 2] - y) < 0.01f
        })
    }

    private fun renderPage(file: File, bitmap: Bitmap, pageIndex: Int = 0) {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRendererPreV(descriptor).use { renderer ->
                renderer.openPage(pageIndex).use { page ->
                    page.render(
                        bitmap,
                        null,
                        null,
                        RenderParams.Builder(RenderParams.RENDER_MODE_FOR_DISPLAY).build(),
                    )
                }
            }
        }
    }
}
