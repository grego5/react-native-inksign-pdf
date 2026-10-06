package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PreparedTextResolverTest {
  @Test
  fun shortGlyphDoesNotShrinkLabelHeightForAdjacentRuleSelection() {
    val text = "טכנאי"
    val glyphs = text.mapIndexed { index, char ->
      val top = if (index == 4) 670.98 else 670.91
      val bottom = if (index == 4) 673.65 else 675.85
      PdfiumPreparedGlyph(char.code,
        PdfiumTextKeyMatch(160.0 - index * 4, top, 163.0 - index * 4, bottom,
          index.toDouble(), (top + bottom) / 2, bottom - top), 0)
    }
    val label = completeLabelMatches(
      preparedTextLabels(PdfiumPreparedPageAnalysis(595.0, 842.0, glyphs, emptyList())), text,
    ).single()
    val rule = PdfiumHorizontalSnapCandidate(43.5, 137.25, 678.0)
    val placement = selectPdfiumTextKeyPlacement(listOf(label.match), listOf(rule),
      TextKeyOccurrence.LAST, true, PdfPageDimensions(595.0, 842.0))

    assertEquals(4.94, label.match.lineHeight, 0.001)
    assertEquals(rule, placement?.rule)
  }

  @Test
  fun labelRangesExcludeOnlyLabelGlyphsFromEmbeddedValueDetection() {
    val glyphs = buildList {
      "Name".forEachIndexed { index, char -> add(glyph(char, index * 6.0, 0.0, 0)) }
      add(glyph('X', 27.0, 0.0, -1))
      add(glyph(' ', 33.0, 0.0, -1))
      "Surname".forEachIndexed { index, char -> add(glyph(char, 33.0 + index * 6.0, 0.0, 0)) }
    }
    val analysis = PdfiumPreparedPageAnalysis(200.0, 100.0, glyphs, emptyList())
    val label = completeLabelMatches(preparedTextLabels(analysis), "Surname Name").single()

    assertEquals(listOf(0..3, 6..12), label.sourceRanges)
    assertEquals("X", embeddedTextInCanonicalRegion(glyphs, PageRect(26.0, 0.0, 33.0, 10.0), label.sourceRanges))
    assertTrue(embeddedTextInCanonicalRegion(glyphs, PageRect(0.0, 0.0, 24.0, 10.0), label.sourceRanges).isEmpty())
  }

  private fun glyph(char: Char, left: Double, top: Double, row: Int) = PdfiumPreparedGlyph(
    codepoint = char.code,
    bounds = PdfiumTextKeyMatch(left, top, left + 5.0, top + 10.0, left, top + 5.0, 10.0),
    visualRow = row,
  )
}
