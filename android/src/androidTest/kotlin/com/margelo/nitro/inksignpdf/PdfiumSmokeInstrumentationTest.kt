package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@SmallTest
class PdfiumSmokeInstrumentationTest {
  @Before
  fun loadNativeModule() {
    NativeTestRuntime.initialize()
  }

  @Test
  fun finalNativeModuleInitializesAndDestroysPdfium() {
    assertTrue(NativeTestRuntime.pdfiumSmokeNative())
  }

  @Test
  fun sharedSessionOwnsBytesAndTemporaryPageHandles() {
    assertTrue(NativeTestRuntime.pdfiumSessionLifecycleNative())
  }

  @Test
  fun pageAssemblyPreservesOrderAndRejectsInvalidMutations() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val jpeg = ByteArrayOutputStream().use { output ->
      val bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
      try {
        check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output))
      } finally {
        bitmap.recycle()
      }
      output.toByteArray()
    }
    val scratchPath = context.cacheDir.resolve("pdfium-assembly-smoke").absolutePath
    assertTrue(NativeTestRuntime.pdfiumAssemblyNative(scratchPath, jpeg))
  }

  @Test
  fun renderBridgeWritesIntoArgbBitmap() {
    val session = PdfiumRenderSession.open(textPdf())
    try {
      val bitmap = Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888)
      try {
        assertTrue(
          session.renderPageIntoBitmap(
            pageIndex = 0,
            bitmap = bitmap,
            pageToDevice = PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
            clip = PdfiumRect(0.0, 0.0, 100.0, 100.0),
          ),
        )
      } finally {
        bitmap.recycle()
      }
    } finally {
      session.close()
    }
  }

  @Test
  fun retainedRenderPageMatchesFreshSessionsAcrossTransformsAndPageSwitches() {
    val document = PdfDocument()
    val source = try {
      for (index in 0..1) {
        val page = document.startPage(PdfDocument.PageInfo.Builder(128, 96, index + 1).create())
        val image = Bitmap.createBitmap(128, 96, Bitmap.Config.ARGB_8888)
        try {
          val canvas = Canvas(image)
          canvas.drawColor(if (index == 0) Color.RED else Color.BLUE)
          val paint = Paint().apply { color = if (index == 0) Color.GREEN else Color.YELLOW }
          canvas.drawRect(32f, 16f, 80f, 64f, paint)
          page.canvas.drawBitmap(image, null, RectF(0f, 0f, 128f, 96f), null)
        } finally { image.recycle() }
        document.finishPage(page)
      }
      ByteArrayOutputStream().use { output -> document.writeTo(output); output.toByteArray() }
    } finally { document.close() }
    val identity = PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    val requests = listOf(
      0 to identity,
      0 to PdfiumAffineMatrix(2.0, 0.0, 0.0, 2.0, -48.0, -24.0),
      0 to PdfiumAffineMatrix(0.0, 1.0, -1.0, 0.0, 128.0, 0.0),
      1 to identity,
      1 to PdfiumAffineMatrix(2.0, 0.0, 0.0, 2.0, -48.0, -24.0),
      0 to identity,
    )
    fun render(session: PdfiumRenderSession, page: Int, matrix: PdfiumAffineMatrix): Bitmap {
      val bitmap = Bitmap.createBitmap(128, 96, Bitmap.Config.ARGB_8888)
      try {
        assertTrue(session.renderPageIntoBitmap(page, bitmap, matrix,
          PdfiumRect(0.0, 0.0, 128.0, 96.0), flags = pdfiumAndroidDisplayFlags))
        return bitmap
      } catch (failure: Throwable) { bitmap.recycle(); throw failure }
    }
    PdfiumRenderSession.open(source).use { retained ->
      var firstPagePixel: Int? = null
      for ((page, matrix) in requests) {
        val actual = render(retained, page, matrix)
        try {
          PdfiumRenderSession.open(source).use { fresh ->
            val expected = render(fresh, page, matrix)
            try { assertTrue("Retained page $page must match a fresh render at $matrix", actual.sameAs(expected)) }
            finally { expected.recycle() }
          }
          if (matrix == identity) {
            val pixel = actual.getPixel(8, 8)
            assertNotEquals("The source image must be visible", Color.WHITE, pixel)
            if (page == 0) firstPagePixel = pixel else assertNotEquals(firstPagePixel, pixel)
          }
        } finally { actual.recycle() }
      }
    }
  }

  @Test
  fun preparedAnalysisFoldsAsciiAndReturnsCompleteLabelBounds() {
    PdfiumRenderSession.open(textPdf()).use { session ->
      val labels = preparedTextLabels(session.preparePageAnalysis(0))
      val matches = completeLabelMatches(labels, "ab")
      assertTrue("The complete source label should match once", matches.size == 1)
      val match = matches.single().match
      assertTrue(match.left >= 0.0 && match.right > match.left)
      assertTrue(match.top >= 0.0 && match.bottom > match.top)
      assertTrue(match.sourceIndex == 0.0 && match.lineHeight > 0.0)
      assertTrue(completeLabelMatches(labels, "missing").isEmpty())
    }
  }

  @Test
  fun reopenedDocumentDoesNotReusePreviousPageAnalysis() {
    PdfiumRenderSession.open(textPdf()).use { original ->
      assertTrue(completeLabelMatches(
        preparedTextLabels(original.preparePageAnalysis(0)), "CD",
      ).isEmpty())
    }
    PdfiumRenderSession.open(multilineTextPdf()).use { replacement ->
      assertTrue(completeLabelMatches(
        preparedTextLabels(replacement.preparePageAnalysis(0)), "CD",
      ).isNotEmpty())
    }
  }

  @Test
  fun preparedLabelsKeepVisualLinesSeparate() {
    PdfiumRenderSession.open(multilineTextPdf()).use { session ->
      val labels = preparedTextLabels(session.preparePageAnalysis(0))
      assertEquals(1, completeLabelMatches(labels, "AB").size)
      assertEquals(1, completeLabelMatches(labels, "CD").size)
      assertTrue(completeLabelMatches(labels, "AB CD").isEmpty())
    }
  }

  @Test
  fun pdfiumMultiwordKeyKeepsAExtractedSpaceWithoutGlyphGeometry() {
    PdfiumRenderSession.open(separatedWordsTextPdf()).use { session ->
      val labels = preparedTextLabels(session.preparePageAnalysis(0))
      val lookup = completeLabelMatches(labels, "Full Name")
      assertTrue("Nearby complete words should form one visual label", lookup.isNotEmpty())
      val scans = session.pageAnalysisScanCountsForTesting()
      assertEquals("lookup=$lookup scans=${scans.toList()}", 1, lookup.size)
      val match = lookup.single().match
      assertTrue(match.lineHeight > 0.0)
      assertTrue(match.lineCenter in match.top..match.bottom)
      assertEquals(lookup.map { it.identity }, completeLabelMatches(labels, "Name Full").map { it.identity })
      assertTrue(completeLabelMatches(labels, "Full Nam").isEmpty())
      assertEquals("The fixture should include a character without geometry", scans[3] - 1, scans[4])
    }
  }

  @Test
  fun pdfiumMultiwordKeyDoesNotCombineDistantFieldsOnOneRow() {
    val content = "BT /F1 12 Tf 1 0 0 1 10 60 Tm (Full) Tj " +
      "1 0 0 1 250 60 Tm (Name) Tj ET\n"
    PdfiumRenderSession.open(textPagePdf(content, pageWidth = 400)).use { session ->
      val labels = preparedTextLabels(session.preparePageAnalysis(0))
      assertTrue(completeLabelMatches(labels, "Full").isNotEmpty())
      assertTrue(completeLabelMatches(labels, "Name").isNotEmpty())
      assertTrue(completeLabelMatches(labels, "Full Name").isEmpty())
    }
  }

  @Test
  fun pdfiumPlacementPathsReusePageTextAndRuleAnalysis() {
    PdfiumRenderSession.open(textPdf()).use { session ->
      val first = session.preparePageAnalysis(0)
      val second = session.preparePageAnalysis(0)
      assertEquals(first, second)
      assertEquals(1, completeLabelMatches(preparedTextLabels(second), "AB").size)

      val scans = session.pageAnalysisScanCountsForTesting()
      assertEquals(1, scans[0])
      assertEquals(1, scans[1])
      assertEquals(1, scans[2])
    }
  }

  @Test
  fun suppliedDiagnosticPdfsExposeBothHorizontalRuleStyles() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val testAssets = instrumentation.context.assets
    val linePdf = testAssets.open("horizontal-rule-lines.pdf").use { it.readBytes() }
    val filledRowPdf = testAssets.open("filled-dot-row.pdf").use { it.readBytes() }
    PdfiumRenderSession.open(linePdf).use { lineSession ->
      PdfiumRenderSession.open(filledRowPdf).use { filledRowSession ->
        val lineCandidates = lineSession.horizontalSnapCandidates(0)
        val filledRowCandidates = filledRowSession.horizontalSnapCandidates(0)
        val linePage = lineSession.pageSize(0)
        val filledRowPage = filledRowSession.pageSize(0)
        assertTrue("The line-rule fixture should expose horizontal paths", lineCandidates.isNotEmpty())
        assertTrue(
          "The filled-row fixture should expose aligned shape rows",
          filledRowCandidates.isNotEmpty(),
        )
        val candidatesByPage = listOf(
          lineCandidates to linePage,
          filledRowCandidates to filledRowPage,
        )
        candidatesByPage.forEach { (candidates, page) ->
          candidates.forEach { candidate ->
            assertTrue(candidate.left >= 0.0 && candidate.left <= candidate.right)
            assertTrue(candidate.right <= page.width)
            assertTrue(candidate.y in 0.0..page.height)
          }
        }
        val transform = PageTransform(3.0, 0.0, 0.0, 3.0, 0.0, 0.0)
        (lineCandidates + filledRowCandidates).forEach { candidate ->
          val centerX = (candidate.left + candidate.right) / 2.0
          assertTrue(
            nearestTextSnapCandidate(
              PagePoint(centerX, candidate.y + 3.0), transform, listOf(candidate), 12.0,
            ) == candidate,
          )
          assertNull(
            nearestTextSnapCandidate(
              PagePoint(centerX, candidate.y + 5.0), transform, listOf(candidate), 12.0,
            ),
          )
        }
      }
    }
  }

  @Test
  fun pdfiumJoinsCloselySpacedSquareShapesIntoADottedRule() {
    val content = buildString {
      append("0.4 0 0 0.4 0 0 cm\n")
      for (x in 20..220 step 2) append("$x 100 1 1 re f\n")
    }
    PdfiumRenderSession.open(textPagePdf(content, pageWidth = 160)).use { session ->
      val rules = session.horizontalSnapCandidates(0)
      assertTrue(
        "A scaled row of small squares should form a usable dotted rule: $rules",
        rules.any { it.right - it.left >= 70.0 },
      )
    }
  }

  @Test
  fun suppliedFallbackChangesRenderingOfAnUnavailableSourceFont() {
    val fallback = listOf(
      File("/system/fonts/Roboto-Regular.ttf"),
      File("/system/fonts/NotoSans-Regular.ttf"),
    ).firstOrNull(File::canRead)
    assumeTrue("No readable Android fallback font is available", fallback != null)

    val source = missingFontPdf()
    val withoutFallback = renderPixels(source, null)
    val withFallback = renderPixels(
      source,
      PdfFallbackFont(fallback!!.absolutePath, null),
    )

    assertTrue(
      "The supplied-font render should contain visible text",
      withFallback.any { it != -1 },
    )
    assertNotEquals(
      "The supplied font should affect rendering of a missing source font",
      withoutFallback.toList(),
      withFallback.toList(),
    )
  }

  @Test
  fun appPreloadedFontUriResolvesAndRendersWithoutFetchingFallbackUrl() = runBlocking {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val cacheFile = File(context.cacheDir, "inksign-test-font/fallback.ttf")
    check(cacheFile.parentFile?.mkdirs() == true || cacheFile.parentFile?.isDirectory == true)
    InstrumentationRegistry.getInstrumentation().context.assets
      .open("liberation-sans-regular.ttf").use { source ->
        cacheFile.outputStream().use { destination -> source.copyTo(destination) }
      }
    val resolver = AndroidFallbackFontResolver(openConnection = {
      throw AssertionError("A valid app-preloaded font must not fetch its fallback URL")
    })

    val resolved = resolver.resolve(AndroidFallbackFont(
      url = "https://assets.example.test/fonts/fallback.ttf",
      uri = cacheFile.absolutePath,
      collectionIndex = null,
    ))
    assertEquals(cacheFile.canonicalPath, resolved.path)

    val source = missingFontPdf()
    val withoutFallback = renderPixels(source, null)
    val withFallback = renderPixels(source, resolved)
    assertNotEquals(withoutFallback.toList(), withFallback.toList())
  }

  private fun renderPixels(
    document: ByteArray,
    fallbackFont: PdfFallbackFont?,
  ): IntArray {
    val session = PdfiumRenderSession.open(document, fallbackFont)
    try {
      val bitmap = Bitmap.createBitmap(160, 100, Bitmap.Config.ARGB_8888)
      try {
        check(
          session.renderPageIntoBitmap(
            pageIndex = 0,
            bitmap = bitmap,
            pageToDevice = PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
            clip = PdfiumRect(0.0, 0.0, 160.0, 100.0),
          ),
        )
        return IntArray(bitmap.width * bitmap.height).also { pixels ->
          bitmap.getPixels(
            pixels,
            0,
            bitmap.width,
            0,
            0,
            bitmap.width,
            bitmap.height,
          )
        }
      } finally {
        bitmap.recycle()
      }
    } finally {
      session.close()
    }
  }

  private fun missingFontPdf(): ByteArray {
    val content = "BT /F1 32 Tf 1 0 0 1 10 35 Tm (MMMM) Tj ET\n"
    val contentLength = content.toByteArray(Charsets.ISO_8859_1).size
    val objects = listOf(
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 160 100] " +
        "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n",
      "4 0 obj\n<< /Length $contentLength >>\nstream\n$content\nendstream\nendobj\n",
      "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /MissingInkSignFont >>\nendobj\n",
    )
    val pdf = StringBuilder("%PDF-1.4\n")
    val offsets = objects.map { objectText ->
      val offset = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
      pdf.append(objectText)
      offset
    }
    val xrefOffset = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
    pdf.append("xref\n0 6\n0000000000 65535 f \n")
    offsets.forEach { offset -> pdf.append("%010d 00000 n \n".format(offset)) }
    pdf.append("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n")
    pdf.append(xrefOffset).append("\n%%EOF\n")
    return pdf.toString().toByteArray(Charsets.ISO_8859_1)
  }

  private fun textPdf(): ByteArray {
    return textPagePdf("BT /F1 20 Tf 1 0 0 1 10 60 Tm (AB) Tj ET\n")
  }

  private fun multilineTextPdf(): ByteArray {
    return textPagePdf("BT /F1 20 Tf 1 0 0 1 10 70 Tm (AB) Tj 0 -30 Td (CD) Tj ET\n")
  }

  private fun separatedWordsTextPdf(): ByteArray {
    val content = "BT /F1 20 Tf 1 0 0 1 10 60 Tm (Full) Tj ET\n" +
      "BT /F1 20 Tf 1 0 0 1 49 60 Tm (Name) Tj ET\n"
    return textPagePdf(content, pageWidth = 120)
  }

  private fun textPagePdf(content: String, pageWidth: Int = 100): ByteArray {
    val objects = listOf(
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pageWidth 100] " +
        "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n",
      "4 0 obj\n<< /Length ${content.toByteArray(Charsets.ISO_8859_1).size} >>\n" +
        "stream\n$content\nendstream\nendobj\n",
      "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    )
    val pdf = StringBuilder("%PDF-1.4\n")
    val offsets = objects.map { objectText ->
      val offset = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
      pdf.append(objectText)
      offset
    }
    val xrefOffset = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
    pdf.append("xref\n0 6\n0000000000 65535 f \n")
    offsets.forEach { offset -> pdf.append("%010d 00000 n \n".format(offset)) }
    pdf.append("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n")
    pdf.append(xrefOffset).append("\n%%EOF\n")
    return pdf.toString().toByteArray(Charsets.ISO_8859_1)
  }
}
