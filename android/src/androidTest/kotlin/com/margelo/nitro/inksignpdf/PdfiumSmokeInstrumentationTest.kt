package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
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
