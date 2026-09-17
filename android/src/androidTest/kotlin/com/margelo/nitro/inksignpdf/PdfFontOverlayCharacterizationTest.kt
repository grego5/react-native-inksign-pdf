package com.margelo.nitro.inksignpdf

import android.graphics.Color
import android.graphics.pdf.PdfRendererPreV
import android.graphics.pdf.component.PdfPageTextObject
import android.os.Build
import android.os.ext.SdkExtensions
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class PdfFontOverlayCharacterizationTest {
  @Test
  fun platformRecoversUnicodeAndPlacementFromUnembeddedIdentityFont() {
    assumeTrue(
      "PdfRendererPreV requires Android S extension 18",
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
        SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 18,
    )

    val context = InstrumentationRegistry.getInstrumentation().targetContext
    context.assets.openFd(FIXTURE_ASSET).use { asset ->
      PdfRendererPreV(asset.parcelFileDescriptor).use { renderer ->
        assertEquals(1, renderer.pageCount)
        renderer.openPage(0).use { page ->
          assertEquals(240, page.width)
          assertEquals(160, page.height)

          val textObjects = page.getPageObjects()
            .map { it.second }
            .filterIsInstance<PdfPageTextObject>()
          assertEquals(listOf("2026: שלום", "A-7"), textObjects.map { it.text })

          val first = textObjects[0]
          assertEquals(18.0f, first.fontSize, 0.001f)
          assertEquals(Color.BLACK, first.fillColor)
          assertEquals(PdfPageTextObject.RENDER_MODE_FILL, first.renderMode)
          assertMatrix(first.matrix, floatArrayOf(1f, 0f, 0f, 1f, 24f, 96f))

          val second = textObjects[1]
          assertEquals(12.0f, second.fontSize, 0.001f)
          assertEquals(Color.BLACK, second.fillColor)
          assertEquals(PdfPageTextObject.RENDER_MODE_FILL, second.renderMode)
          assertMatrix(second.matrix, floatArrayOf(1f, 0f, 0f, 1f, 92f, 52f))
        }
      }
    }
  }

  private fun assertMatrix(actual: FloatArray, expected: FloatArray) {
    assertEquals(expected.size, actual.size)
    actual.forEach { value -> assertTrue("matrix must be finite", value.isFinite()) }
    expected.indices.forEach { index ->
      assertTrue(
        "matrix[$index] differs: expected ${expected[index]}, actual ${actual[index]}",
        abs(expected[index] - actual[index]) <= 0.001f,
      )
    }
  }

  private companion object {
    const val FIXTURE_ASSET = "nonembedded-identity-text.pdf"
  }
}
