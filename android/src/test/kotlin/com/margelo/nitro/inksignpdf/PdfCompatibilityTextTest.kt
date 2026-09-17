package com.margelo.nitro.inksignpdf

import android.graphics.RectF
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfCompatibilityTextTest {
  private fun rect(left: Float, top: Float, right: Float, bottom: Float): RectF {
    return RectF().apply {
      this.left = left
      this.top = top
      this.right = right
      this.bottom = bottom
    }
  }

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
  fun groupedCandidatesPreserveInternalAsciiAndPunctuation() {
    val candidates = groupCompatibilityTextCandidates("א ב,ג A ד") { scalar ->
      scalar in setOf("א", "ב", "ג", "ד")
    }

    assertEquals(listOf("א ב,ג A ד"), candidates.map { it.text })
    assertEquals(0, candidates.first().start)
    assertEquals("א ב,ג A ד".length, candidates.first().end)
  }

  @Test
  fun groupedCandidatesPreserveMultipleBridgesBetweenHebrewScalars() {
    val candidates = groupCompatibilityTextCandidates("ש\"  ח מע\"מ 123א") { scalar ->
      scalar in setOf("ש", "ח", "מ", "ע", "א")
    }

    assertEquals(listOf("ש\"  ח מע\"מ 123א"), candidates.map { it.text })
  }

  @Test
  fun groupedCandidatesStopAtNewlineAndControlCharacters() {
    val candidates = groupCompatibilityTextCandidates("א  ב\nג\u0001 ד") { scalar ->
      scalar in setOf("א", "ב", "ג", "ד")
    }

    assertEquals(listOf("א  ב", "ג", "ד"), candidates.map { it.text })
  }

  @Test
  fun groupedCandidatesExcludeLeadingAndTrailingBridges() {
    val candidates = groupCompatibilityTextCandidates(" A  א  B ") { scalar ->
      scalar == "א"
    }

    assertEquals(listOf("א"), candidates.map { it.text })
  }

  @Test
  fun groupedCandidatesDoNotRetainTrailingJoiners() {
    val candidates = groupCompatibilityTextCandidates("א ") { true }

    assertEquals(listOf("א"), candidates.map { it.text })
  }

  @Test
  fun sameLineFragmentsAreUnionedWithoutSplittingText() {
    val geometry = mergeCompatibilityTextFragments(
      text = "אבג",
      bounds = listOf(
        rect(40f, 20f, 55f, 30f),
        rect(10f, 21f, 25f, 29f),
        rect(24f, 20f, 42f, 30f),
      ),
      selectionStartX = 8f,
      selectionStopX = 60f,
    )

    assertTrue(geometry?.mergedSameLine == true)
    assertEquals(3, geometry?.fragmentCount)
    assertEquals(1, geometry?.bounds?.size)
    geometry?.bounds?.single()?.let { merged ->
      assertEquals(8f, merged.left)
      assertEquals(20f, merged.top)
      assertEquals(60f, merged.right)
      assertEquals(30f, merged.bottom)
    } ?: error("Expected one merged rectangle")
    assertEquals(10f, geometry?.selectionLeft)
    assertEquals(55f, geometry?.selectionRight)
    assertEquals(8f, geometry?.boundaryLeft)
    assertEquals(60f, geometry?.boundaryRight)
    assertEquals(8f, geometry?.fullSpanLeft)
    assertEquals(60f, geometry?.fullSpanRight)
    assertEquals(listOf("אבג"), geometry?.textParts)
  }

  @Test
  fun distinctLinesRequireExplicitTextLines() {
    val bounds = listOf(
      rect(10f, 20f, 40f, 30f),
      rect(10f, 40f, 40f, 50f),
    )

    val ambiguous = mergeCompatibilityTextFragments("אבג", bounds)
    assertEquals(2, ambiguous?.bounds?.size)
    assertNull(ambiguous?.textParts)

    val explicit = mergeCompatibilityTextFragments("א\nב", bounds)
    assertEquals(listOf("א", "ב"), explicit?.textParts)
  }

  @Test
  fun onePointSelectionMatchesContainingLineByHorizontalOverlap() {
    val lines = listOf(
      PdfCompatibilityTextLine(
        source = PdfCompatibilityTextLineSource.TEXT_CONTENTS,
        index = 0,
        bounds = rect(0f, 20f, 100f, 30f),
      ),
      PdfCompatibilityTextLine(
        source = PdfCompatibilityTextLineSource.TEXT_CONTENTS,
        index = 1,
        bounds = rect(120f, 20f, 240f, 30f),
      ),
    )

    val match = matchCompatibilityTextLine(rect(150f, 25f, 151f, 26f), lines)

    assertEquals(1, match?.index)
  }

  @Test
  fun horizontalOverlapWinsBeforeVerticalCenterDistance() {
    val lines = listOf(
      PdfCompatibilityTextLine(
        source = PdfCompatibilityTextLineSource.TEXT_CONTENTS,
        index = 0,
        bounds = rect(0f, 20f, 108f, 30f),
      ),
      PdfCompatibilityTextLine(
        source = PdfCompatibilityTextLineSource.TEXT_CONTENTS,
        index = 1,
        bounds = rect(102f, 22f, 200f, 32f),
      ),
    )

    val match = matchCompatibilityTextLine(rect(105f, 25f, 115f, 26f), lines)

    assertEquals(1, match?.index)
  }

  @Test
  fun missingLineAllowsOnlyUsableStandaloneFallback() {
    val lines = listOf(
      PdfCompatibilityTextLine(
        source = PdfCompatibilityTextLineSource.TEXT_CONTENTS,
        index = 0,
        bounds = rect(0f, 20f, 100f, 30f),
      ),
    )

    assertNull(matchCompatibilityTextLine(rect(150f, 25f, 160f, 26f), lines))
    assertNull(matchCompatibilityTextLine(rect(150f, 35f, 160f, 36f), lines))
    assertTrue(isUsableCompatibilityStandaloneBounds(rect(150f, 25f, 160f, 30f)))
    assertFalse(isUsableCompatibilityStandaloneBounds(rect(150f, 25f, 160f, 26f)))
  }

}
