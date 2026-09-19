package com.margelo.nitro.inksignpdf

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
  fun geometryBridgeReturnsCopiedPositionedCharacterValues() {
    val session = PdfiumGeometrySession.open(textPdf())
    try {
      assertEquals(1, session.pageCount)
      val page = session.extractPage(0)
      assertEquals(0, page.pageIndex)
      assertEquals(2, page.characters.size)
      assertEquals('A'.code.toLong(), page.characters[0].unicode)
      assertEquals('B'.code.toLong(), page.characters[1].unicode)
      assertTrue(page.characters[1].origin.x > page.characters[0].origin.x)
      assertTrue(page.characters.all { character ->
        character.origin.x.isFinite() && character.origin.y.isFinite() &&
          character.bounds.left.isFinite() && character.bounds.top.isFinite() &&
          character.matrix.a.isFinite() && character.matrix.f.isFinite()
      })
    } finally {
      session.close()
    }
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
