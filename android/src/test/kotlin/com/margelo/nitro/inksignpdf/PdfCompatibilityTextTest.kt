package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
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

  @Test
  fun groupedCandidatesKeepOnlyInternalWhitespaceAndPunctuation() {
    val candidates = groupCompatibilityTextCandidates("א ב,ג A ד") { scalar ->
      scalar in setOf("א", "ב", "ג", "ד")
    }

    assertEquals(listOf("א ב,ג", "ד"), candidates.map { it.text })
    assertEquals(0, candidates.first().start)
    assertEquals(5, candidates.first().end)
  }

  @Test
  fun groupedCandidatesDoNotRetainTrailingJoiners() {
    val candidates = groupCompatibilityTextCandidates("א ") { true }

    assertEquals(listOf("א"), candidates.map { it.text })
  }

}
