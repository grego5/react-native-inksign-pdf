package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.fonts.Font
import android.graphics.text.PositionedGlyphs
import android.graphics.text.TextRunShaper
import android.os.Build
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.TextShaper
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class PdfExportContourTest {
    @Before
    fun initializeNativeRuntime() {
        NativeTestRuntime.initialize()
        PDFBoxResourceLoader.init(
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext,
        )
    }

    @Test
    fun exporterWritesIndependentFilledContourObjectsAndRasterizedOverlap() {
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
            val bitmap = Bitmap.createBitmap(50, 50, Bitmap.Config.ARGB_8888)
            try {
                renderPage(output, bitmap)
                val overlap = bitmap.getPixel(20, 20)
                assertTrue("The overlapping contours must remain opaque ink", Color.alpha(overlap) >= 240)
                assertTrue("The overlapping contours must remain black", Color.red(overlap) < 8)
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
            val bitmap = Bitmap.createBitmap(50, 50, Bitmap.Config.ARGB_8888)
            try {
                renderPage(output, bitmap)
                assertTrue("The fractional contour must render as a filled vector shape", darkPixelCount(bitmap, Rect(10, 10, 32, 33)) > 20)
                assertEquals(0, darkPixelCount(bitmap, Rect(0, 0, 8, 8)))
            } finally {
                bitmap.recycle()
            }
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    @Test
    fun exporterPreservesEveryPageAndPlacesInkOnMatchingPages() {
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
            PdfiumRenderSession.open(output.readBytes()).use { renderer ->
                assertEquals(3, renderer.pageCount)
                pageSizes.forEachIndexed { pageIndex, size ->
                    val page = renderer.pageSize(pageIndex)
                    assertEquals(size.first.toDouble(), page.width, 0.0)
                    assertEquals(size.second.toDouble(), page.height, 0.0)
                }
            }
            pageSizes.forEachIndexed { pageIndex, size ->
                val bitmap = Bitmap.createBitmap(size.first, size.second, Bitmap.Config.ARGB_8888)
                try {
                    renderPage(output, bitmap, pageIndex)
                    val inkPixels = darkPixelCount(bitmap, Rect(0, 0, size.first, size.second))
                    assertEquals(pageIndex < 2, inkPixels > 0)
                } finally {
                    bitmap.recycle()
                }
            }
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    @Test
    fun exporterWritesUnicodeTextObjectsWithExplicitLinePlacement() {
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .targetContext
        val policy = CacheArtifactPolicy.initialize(context)
        val source = File.createTempFile("text-export-source-", ".pdf", context.cacheDir)
        val output = policy.allocateSignedOutput()
        try {
            writeBlankPdf(source, listOf(240 to 160))
            val annotation = TextAnnotation(
                id = "text-1",
                text = "Latin\n\nשלום العربية\nMixed Latin שלום العربية\nनमस्ते दुनिया",
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

            val resolved = PdfExportTextResolver.resolve(snapshot)
            assertTrue("Text resolver must produce source-mapped runs", resolved.runs.isNotEmpty())
            assertTrue("Every segment must retain the fixed LTR base direction", resolved.runs.all {
                !it.baseDirectionRtl && it.boundsLeft == annotation.bounds.left.toFloat() &&
                    it.boundsRight == annotation.bounds.right.toFloat()
            })
            PdfExporter.export(snapshot, policy) { false }
            val extractedText = extractTextWithPdfBox(output)
            val logicalText = extractedText.replace("\uFEFF", "")
            assertEquals(
                "PDFBox must extract the logical annotation text",
                "Latin שלום العربية Mixed Latin שלום العربية नमस्ते दुनिया",
                logicalText.replace(Regex("\\s+"), " ").trim(),
            )

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
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    @Test
    fun pre31BestEffortPathKeepsLogicalActualTextWithoutEmbeddingSystemFonts() {
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .targetContext
        val policy = CacheArtifactPolicy.initialize(context)
        val source = File.createTempFile("legacy-text-source-", ".pdf", context.cacheDir)
        val candidate = policy.allocateExportScratch()
        try {
            writeBlankPdf(source, listOf(240 to 120))
            val annotation = TextAnnotation(
                id = "legacy-text-1",
                text = "abc שלום العربية",
                bounds = PageRect(24.0, 28.0, 216.0, 72.0),
                fontSize = 14.0,
                directionRtl = true,
            )
            val snapshot = PdfExportSnapshot(
                sourcePath = source.path,
                outputPath = candidate.path,
                pages = listOf(
                    PdfPageExportSnapshot(
                        pageIndex = 0,
                        dimensions = PdfPageDimensions(240.0, 120.0),
                        strokes = emptyList(),
                        textAnnotations = listOf(annotation),
                    ),
                ),
                generation = 1L,
                color = Color.BLACK,
            )

            val resolved = PdfExportTextResolver.resolve(
                snapshot,
                apiLevel = Build.VERSION_CODES.R,
            )
            assertTrue("Pre-31 exports must not package Android font resources", resolved.fonts.isEmpty())
            assertEquals(1, resolved.runs.size)
            assertEquals(-1, resolved.runs.single().fontIndex)
            assertTrue("The saved annotation direction must reach the legacy run", resolved.runs.single().baseDirectionRtl)
            PdfiumNativePdfExporter.export(snapshot, resolved, candidate)

            val expectedActualTextHex = annotation.text
                .map { it.code.toString(16).uppercase().padStart(4, '0') }
                .joinToString(separator = "")
            val actualTextHex = Regex("/ActualText<FEFF([0-9A-F]+)>")
                .find(readPageContent(candidate))
                ?.groupValues
                ?.get(1)
            assertEquals(
                "The legacy fallback must store logical text as UTF-16 ActualText",
                expectedActualTextHex,
                actualTextHex,
            )
        } finally {
            source.delete()
            policy.deleteExact(candidate)
        }
    }

    @Test
    fun androidFontResolutionProvidesPerGlyphDataAndPdfiumAcceptsAnEmbeddableSelection() {
        assumeTrue("TextRunShaper requires API 31", Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 18f }
        val samples = listOf(
            "Latin sample" to false,
            "שלום עולם" to true,
            "العربية" to true,
            "नमस्ते दुनिया" to false,
        )
        val selectedFonts = linkedMapOf<Pair<Int, Int>, SelectedFontProbe>()
        val shapedRuns = mutableListOf<Pair<String, PositionedGlyphs>>()
        samples.forEach { (text, isRtl) ->
            val glyphs = TextRunShaper.shapeTextRun(
                text,
                0,
                text.length,
                0,
                text.length,
                0f,
                0f,
                isRtl,
                paint,
            )
            assertTrue("Android must shape $text", glyphs.glyphCount() > 0)
            assertTrue("Android must measure $text", glyphs.advance > 0f)
            shapedRuns += text to glyphs
            for (index in 0 until glyphs.glyphCount()) {
                val font = glyphs.getFont(index)
                val key = font.sourceIdentifier to font.ttcIndex
                selectedFonts.getOrPut(key) { probe(font) }
                assertTrue("Glyph position must be finite for $text", glyphs.getGlyphX(index).isFinite())
                assertTrue("Glyph baseline must be finite for $text", glyphs.getGlyphY(index).isFinite())
            }
        }

        val mixedText = "Latin שלום العربية"
        val mixedGlyphs = mutableListOf<Triple<Int, Int, PositionedGlyphs>>()
        TextShaper.shapeText(
            mixedText,
            0,
            mixedText.length,
            TextDirectionHeuristics.FIRSTSTRONG_LTR,
            paint,
        ) { start, count, glyphs, _ ->
            mixedGlyphs += Triple(start, count, glyphs)
            for (index in 0 until glyphs.glyphCount()) {
                val font = glyphs.getFont(index)
                selectedFonts.getOrPut(font.sourceIdentifier to font.ttcIndex) { probe(font) }
            }
        }
        assertTrue("TextShaper must split mixed-direction text into visual runs", mixedGlyphs.size >= 2)
        assertTrue("Android must resolve real font buffers", selectedFonts.values.all { it.bytes.isNotEmpty() })

        val fontSummary = selectedFonts.values.joinToString { selected ->
            "ttc=${selected.collectionIndex},bytes=${selected.bytes.size},fsType=${selected.fsType}"
        }
        println("Android selected-font prototype: api=${Build.VERSION.SDK_INT}, fonts=[$fontSummary]")
        println("Android shaping prototype: ${shapedRuns.joinToString { (text, glyphs) ->
            "${text.codePointCount(0, text.length)} chars/${glyphs.glyphCount()} glyphs/advance=${glyphs.advance}"
        }}; mixedRuns=${mixedGlyphs.joinToString { (start, count, glyphs) ->
            val range = mixedText.substring(start, start + count)
            "$start+$count '$range' glyphs=${glyphs.glyphCount()} offset=${glyphs.offsetX}," +
                "x=${(0 until glyphs.glyphCount()).joinToString { glyphIndex ->
                    "${glyphs.getGlyphId(glyphIndex)}@${glyphs.getGlyphX(glyphIndex)}"
                }}"
        }}")

        val arabicLigature = "لا"
        val shapedLigature = TextRunShaper.shapeTextRun(
            arabicLigature, 0, arabicLigature.length, 0, arabicLigature.length, 0f, 0f, true, paint,
        )
        val isolatedArabicTargets = (0 until arabicLigature.length).map { index ->
            TextRunShaper.shapeTextRun(
                arabicLigature, index, 1, 0, arabicLigature.length, 0f, 0f, true, paint,
            )
        }
        println("Arabic lam-alef prototype: full=${shapedLigature.glyphCount()}," +
            "per-target=${isolatedArabicTargets.joinToString { it.glyphCount().toString() }}")

        val embeddableHebrew = shapedRuns
            .first { it.first == "שלום עולם" }
            .second
            .let { it.getFont(0) }
            .let(::probe)
        assumeTrue(
            "Selected Hebrew font cannot be embedded under its fsType or needs TTC extraction",
            embeddableHebrew.collectionIndex == 0 && embeddableHebrew.canEmbed,
        )

        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .targetContext
        val policy = CacheArtifactPolicy.initialize(context)
        val source = File.createTempFile("selected-font-source-", ".pdf", context.cacheDir)
        val output = policy.allocateSignedOutput()
        try {
            writeBlankPdf(source, listOf(240 to 100))
            val snapshot = PdfExportSnapshot(
                sourcePath = source.path,
                outputPath = output.path,
                pages = listOf(
                    PdfPageExportSnapshot(
                        pageIndex = 0,
                        dimensions = PdfPageDimensions(240.0, 100.0),
                        strokes = emptyList(),
                        textAnnotations = listOf(
                            TextAnnotation(
                                id = "selected-font",
                                text = "שלום עולם",
                                bounds = PageRect(20.0, 28.0, 220.0, 62.0),
                                fontSize = 18.0,
                                directionRtl = true,
                            ),
                        ),
                    ),
                ),
                generation = 1L,
                color = Color.BLACK,
            )

            PdfExporter.export(snapshot, policy) { false }
            val extracted = extractTextWithPdfBox(output)
            val logicalText = extracted.replace("\uFEFF", "")
            assertTrue(
                "PDFium must retain the selected-font Hebrew text; extracted=$extracted",
                logicalText.contains("שלום"),
            )
            val bitmap = Bitmap.createBitmap(240, 100, Bitmap.Config.ARGB_8888)
            try {
                renderPage(output, bitmap)
                assertTrue(
                    "PDFium must render the selected-font Hebrew text",
                    darkPixelCount(bitmap, Rect(10, 18, 230, 72)) > 25,
                )
            } finally {
                bitmap.recycle()
            }
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    @Test
    fun exporterCountsExistingSourceTextSeparatelyFromAddedText() {
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .targetContext
        val policy = CacheArtifactPolicy.initialize(context)
        val source = File.createTempFile("source-text-export-", ".pdf", context.cacheDir)
        val output = policy.allocateSignedOutput()
        try {
            writePdfWithTextObject(source, 240, 160, "Source")
            assertEquals("Source", extractTextWithPdfBox(source).trim())
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

            val exportedText = extractTextWithPdfBox(output).replace("\uFEFF", "")
                .replace(Regex("\\s+"), " ")
                .trim()
            assertTrue("Existing source text must remain extractable: $exportedText", exportedText.contains("Source"))
            assertTrue("Added vector text must be extractable: $exportedText", exportedText.contains("Added"))
        } finally {
            source.delete()
            policy.deleteExact(output)
        }
    }

    private fun writeBlankPdf(
        file: File,
        pageSizes: List<Pair<Int, Int>> = listOf(50 to 50),
    ) {
        val pageObjectIndices = pageSizes.indices.map { 3 + it }
        val contentObjectIndices = pageSizes.indices.map { 3 + pageSizes.size + it }
        val objects = mutableListOf(
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [${pageObjectIndices.joinToString(separator = " ") { "$it 0 R" }}] /Count ${pageSizes.size} >>",
        )
        pageSizes.forEachIndexed { index, size ->
            objects += "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${size.first} ${size.second}] /Contents ${contentObjectIndices[index]} 0 R >>"
        }
        pageSizes.indices.forEach { objects += "<< /Length 0 >>\nstream\nendstream" }
        writePdfObjects(file, objects)
    }

    private data class SelectedFontProbe(
        val bytes: ByteArray,
        val collectionIndex: Int,
        val fsType: Int?,
        val canEmbed: Boolean,
    )

    private fun probe(font: Font): SelectedFontProbe {
        val buffer: ByteBuffer = font.buffer.duplicate()
        val bytes = ByteArray(buffer.remaining()).also(buffer::get)
        val fsType = readOpenTypeFsType(bytes, font.ttcIndex)
        val permission = fsType?.and(0x000E)
        val canEmbed = (permission == 0 || permission == 0x0008) &&
            fsType?.and(0x0200) == 0 &&
            fsType?.and(0x0100) == 0
        return SelectedFontProbe(bytes, font.ttcIndex, fsType, canEmbed)
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
                        .contentEquals(byteArrayOf(0x4F, 0x53, 0x2F, 0x32))) {
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
        writePdfObjects(file, objects)
    }

    private fun writePdfObjects(file: File, objects: List<String>) {
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

    private fun extractTextWithPdfBox(file: File): String =
        FileInputStream(file).use { input ->
            PDDocument.load(input).use { document ->
                PDFTextStripper().getText(document)
            }
        }

    private fun readPageContent(file: File): String =
        FileInputStream(file).use { input ->
            PDDocument.load(input).use { document ->
                document.getPage(0).contents.use { content ->
                    String(content.readBytes(), Charsets.ISO_8859_1)
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

    private fun renderPage(file: File, bitmap: Bitmap, pageIndex: Int = 0) {
        PdfiumRenderSession.open(file.readBytes()).use { renderer ->
            val page = renderer.pageSize(pageIndex)
            val scaleX = bitmap.width / page.width
            val scaleY = bitmap.height / page.height
            check(
                renderer.renderPageIntoBitmap(
                    pageIndex = pageIndex,
                    bitmap = bitmap,
                    pageToDevice = PdfiumAffineMatrix(scaleX, 0.0, 0.0, scaleY, 0.0, 0.0),
                    clip = PdfiumRect(0.0, 0.0, bitmap.width.toDouble(), bitmap.height.toDouble()),
                    background = Color.WHITE,
                ),
            ) { "PDFium could not render page $pageIndex" }
        }
    }

}
