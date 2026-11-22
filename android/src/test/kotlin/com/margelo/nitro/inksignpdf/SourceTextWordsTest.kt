package com.margelo.nitro.inksignpdf

import org.junit.Assert.*
import org.junit.Test

internal fun sourceWordFixture(text: String, row: Int = 0, top: Double = 0.0): List<PdfiumPreparedGlyph> =
  text.codePoints().toArray().mapIndexed { index, scalar ->
    PdfiumPreparedGlyph(scalar,
      PdfiumTextKeyMatch(index * 10.0, top, index * 10.0 + 8.0, top + 10.0,
        index.toDouble(), top + 5.0, 10.0), row)
  }

class SourceTextWordsTest {
  @Test fun segmentsFollowPhysicalCrossingsAndIgnoreWhitespaceAndOtherRows() {
    val index = SourceTextWords(sourceWordFixture("A B C") + sourceWordFixture("D E", 1, 30.0))
    assertEquals(listOf("A", "B", "C"), index.crossed(PagePoint(-1.0, 5.0), PagePoint(49.0, 5.0)).map { it.text })
    assertEquals(listOf("C", "B", "A"), index.crossed(PagePoint(49.0, 5.0), PagePoint(-1.0, 5.0)).map { it.text })
    assertTrue(index.crossed(PagePoint(10.0, 15.0), PagePoint(48.0, 15.0)).isEmpty())
    assertNull(index.hit(PagePoint(15.0, 5.0), 1.0))
    assertEquals("B", index.hit(PagePoint(19.0, 5.0), 2.0)?.text)
  }

  @Test fun spellingKeepsUnicodePunctuationAndInvisibleScalars() {
    val index = SourceTextWords(sourceWordFixture("Hi!\u00A0שלום مرحبا 😀e\u0301 Hi!"))
    assertEquals(listOf("Hi!", "שלום", "مرحبا", "😀e\u0301", "Hi!"), index.words.map { it.text })
    assertNotEquals(index.words.first().id, index.words.last().id)
    val glyphs = sourceWordFixture("ab").toMutableList()
    glyphs.add(1, PdfiumPreparedGlyph(0x200D, null, -1))
    assertEquals("a\u200Db", SourceTextWords(glyphs).words.single().text)
    assertTrue(SourceTextWords(listOf(PdfiumPreparedGlyph(65, null, -1))).words.isEmpty())
  }

  @Test fun drawableRowChangesSplitRunsAndPreparationCachesCanonicalIndex() {
    val glyphs = sourceWordFixture("A") + sourceWordFixture("B", 1, 30.0)
    assertEquals(listOf("A", "B"), SourceTextWords(glyphs).words.map { it.text })
    val prepared = PreparedPage(1, "page", PdfiumPreparedPageAnalysis(100.0, 100.0, glyphs, emptyList()))
    assertSame(prepared.sourceWords, prepared.sourceWords)
  }

  @Test fun everyContractWhitespaceSplitsButZeroWidthSpaceDoesNot() {
    val whitespace = listOf(9, 10, 11, 12, 13, 32, 0x85, 0xA0, 0x1680) +
      (0x2000..0x200A) + listOf(0x2028, 0x2029, 0x202F, 0x205F, 0x3000)
    whitespace.forEach { scalar ->
      assertEquals(listOf("A", "B"), SourceTextWords(sourceWordFixture("A" + String(Character.toChars(scalar)) + "B")).words.map { it.text })
    }
    assertEquals("A\u200BB", SourceTextWords(sourceWordFixture("A\u200BB")).words.single().text)
  }
}
