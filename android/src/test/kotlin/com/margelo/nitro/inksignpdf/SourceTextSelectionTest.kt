package com.margelo.nitro.inksignpdf

import org.junit.Assert.*
import org.junit.Test

class SourceTextSelectionTest {
  @Test fun boxExpandsShrinksAndCopiesInSourceOrder() {
    val index = SourceTextWords(sourceWordFixture("AA B C"))
    val selection = SourceTextSelection(index)
    selection.begin(index.words[1])
    selection.updateBox(PagePoint(58.0, 10.0))
    assertEquals("B C", selection.copyText())
    selection.updateBox(PagePoint(0.0, 0.0))
    assertEquals("AA B", selection.copyText())
    assertEquals(PageRect(0.0, 0.0, 18.0, 10.0), selection.highlightRectangles.first())
    selection.finish()
    selection.updateBox(PagePoint(58.0, 10.0))
    assertEquals("AA B", selection.copyText())
    selection.clear()
    assertNull(selection.copyText())
  }

  @Test fun boxIncludesInteriorRowsWithoutFollowingTheDragPath() {
    val index = SourceTextWords(sourceWordFixture("A B C") + sourceWordFixture("D", 1, 30.0))
    val selection = SourceTextSelection(index)
    selection.begin(index.words.first())
    selection.updateBox(PagePoint(48.0, 40.0))
    assertEquals("A B C\nD", selection.copyText())
    selection.updateBox(PagePoint(8.0, 10.0))
    assertEquals("A", selection.copyText())
  }
}
