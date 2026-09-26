package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
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
    val content = "BT /F1 20 Tf 1 0 0 1 10 60 Tm (AB) Tj ET\n"
    val objects = listOf(
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] " +
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
