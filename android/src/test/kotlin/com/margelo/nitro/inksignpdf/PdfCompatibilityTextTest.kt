package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfCompatibilityTextTest {
  @Test
  fun universalScalarsRetainAdvanceButAreNeverPaintable() {
    assertFalse(hasPaintableCompatibilityScalar("A 7\n\t") { true })
    assertTrue(hasPaintableCompatibilityScalar("A א") { it == "א" })
    assertFalse(hasPaintableCompatibilityScalar("א") { false })
  }

  @Test
  fun malformedUnicodeIsRejectedBeforeGlyphLookup() {
    assertNull(decodePdfScalars("\uD800"))
    assertNull(decodePdfScalars("\uDC00"))
    assertFalse(hasPaintableCompatibilityScalar("\uD800") { true })
  }

}
