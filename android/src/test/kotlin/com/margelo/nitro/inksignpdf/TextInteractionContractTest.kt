package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TextInteractionContractTest {
  @Test
  fun defaultFontSizeUsesTheSharedPublicRange() {
    assertEquals(16.0, normalizeTextFontSize(null), 0.0)
    assertEquals(16.0, normalizeTextFontSize(Double.NaN), 0.0)
    assertEquals(16.0, normalizeTextFontSize(0.0), 0.0)
    assertEquals(16.0, normalizeTextFontSize(-1.0), 0.0)
    assertEquals(8.0, normalizeTextFontSize(1.0), 0.0)
    assertEquals(24.0, normalizeTextFontSize(24.0), 0.0)
    assertEquals(72.0, normalizeTextFontSize(100.0), 0.0)
  }

  @Test
  fun multilineTextKeepsExplicitNewlinesAndCanonicalPlacement() {
    val annotation = TextAnnotation(
      id = "text-1",
      text = "first\nlongest line",
      bounds = PageRect(42.0, 18.0, 130.0, 54.0),
      fontSize = 16.0,
    )

    assertEquals("first\nlongest line", annotation.text)
    assertEquals(PagePoint(42.0, 18.0), annotation.position)
    assertEquals(88.0, annotation.intrinsicWidth, 0.0)
    assertEquals(36.0, annotation.intrinsicHeight, 0.0)
  }

  @Test
  fun dragOrEditReplacementIsOneUndoableHistoryAction() {
    val history = InkHistory()
    val before = text("text-1", "Hello", 24.0, 30.0)
    val after = text("text-1", "Hello\nworld", 60.0, 48.0, 18.0)

    history.appendText(before)
    history.replaceText(before, after)
    assertEquals(listOf(PageContent.Text(after)), history.contentSnapshot())

    history.undoMutation()
    assertEquals(listOf(PageContent.Text(before)), history.contentSnapshot())
    assertTrue(history.state().canRedo)
  }

  @Test
  fun blankCommittedTextCannotSurviveDismissal() {
    val history = InkHistory()
    val rejected = runCatching {
      history.appendText(text("text-1", "", 0.0, 0.0))
    }

    assertTrue(rejected.isFailure)
    assertTrue(history.contentSnapshot().isEmpty())
  }

  @Test
  fun unchangedExistingTextDismissalDoesNotCreateAHistoryMutation() {
    val history = InkHistory()
    val annotation = text("text-1", "Hello", 24.0, 30.0)
    history.appendText(annotation)

    assertEquals(
      TextEditingMutation.NoOp,
      settleTextEditing(annotation, annotation),
    )
    assertEquals(listOf(PageContent.Text(annotation)), history.contentSnapshot())
    assertTrue(history.state().canUndo)
  }

  @Test
  fun textEditingSettlementClassifiesAppendReplaceRemoveAndNoOp() {
    val before = text("text-1", "Hello", 24.0, 30.0)
    val after = text("text-1", "Updated", 24.0, 30.0)

    assertEquals(TextEditingMutation.Append(after), settleTextEditing(null, after))
    assertEquals(TextEditingMutation.Replace(before, after), settleTextEditing(before, after))
    assertEquals(TextEditingMutation.Remove(before), settleTextEditing(before, null))
    assertEquals(TextEditingMutation.NoOp, settleTextEditing(null, null))
  }

  @Test
  fun initialEditorBoundsUseTheSameMinimumWidthAsFreePlacement() {
    val size = TextIntrinsicSize(64.0, 20.0)
    val placement = chooseTextPlacementPosition(
      PagePoint(150.0, 150.0),
      size,
      page = PdfPageDimensions(300.0, 300.0),
    )

    assertEquals(64.0, size.width, 0.0)
    assertTrue(size.height > 0.0)
    assertEquals(150.0 - size.width / 2.0, placement.x, 0.0)
    assertEquals(150.0 - size.height / 2.0, placement.y, 0.0)
  }

  @Test
  fun presentationGeometryHasAStableScreenSpaceMinimum() {
    val expansion = textPresentationExpansion(10f, 10f, 40f)

    assertEquals(15f, expansion.first, 0f)
    assertEquals(15f, expansion.second, 0f)
  }

  @Test
  fun selectedOutlineUsesTheEditorPixelPaddingAtEveryZoom() {
    val fontSizePx = 16.0 * 7.0

    assertEquals(
      42,
      textEditorPaddingPx(fontSizePx, textEditorHorizontalPaddingRatio),
    )
    assertEquals(
      28,
      textEditorPaddingPx(fontSizePx, textEditorVerticalPaddingRatio),
    )
  }

  @Test
  fun editorMinimumAndWideLineStopsAtThePageEdge() {
    val empty = textEditorPageBoundedSize(
      TextIntrinsicSize(20.0, 18.0),
      minimumPageSize = 80.0,
      pageLeft = 0.0,
      pageRight = 600.0,
      anchorX = 100.0,
      isRtl = false,
    )
    assertEquals(80.0, empty.width, 0.0)
    assertEquals(80.0, empty.height, 0.0)

    val wide = textEditorPageBoundedSize(
      TextIntrinsicSize(900.0, 24.0),
      minimumPageSize = 40.0,
      pageLeft = 0.0,
      pageRight = 600.0,
      anchorX = 100.0,
      isRtl = false,
    )
    assertEquals(500.0, wide.width, 0.0)

    val nearEdge = textEditorPageBoundedSize(
      TextIntrinsicSize(60.0, 24.0),
      minimumPageSize = 40.0,
      pageLeft = 0.0,
      pageRight = 300.0,
      anchorX = 280.0,
      isRtl = false,
    )
    assertEquals(20.0, nearEdge.width, 0.0)
  }

  @Test
  fun rtlEditorKeepsItsRightEdgeWhileGrowingLeft() {
    val wide = textEditorPageBoundedSize(
      TextIntrinsicSize(900.0, 24.0),
      minimumPageSize = 40.0,
      pageLeft = 0.0,
      pageRight = 600.0,
      anchorX = 500.0,
      isRtl = true,
    )
    assertEquals(500.0, wide.width, 0.0)
    assertEquals(
      PageRect(100.0, 20.0, 500.0, 44.0),
      textEditorPageBounds(500.0, 20.0, TextIntrinsicSize(400.0, 24.0), true),
    )
    assertEquals(500.0, textEditorPageBounds(500.0, 20.0, TextIntrinsicSize(80.0, 24.0), true).right, 0.0)
    val transform = PageTransform(2.0, 0.0, 0.0, 2.0, 10.0, 20.0)
    assertEquals(
      500.0,
      textEditorAnchorAfterDirectionChange(
        transform, ViewPoint(1_018.0, 54.0), true,
        paddingLeftPx = 8.0, paddingTopPx = 6.0, paddingRightPx = 8.0,
      ),
      0.0,
    )
    assertEquals(
      420.0,
      textEditorAnchorAfterDirectionChange(
        transform, ViewPoint(842.0, 54.0), false,
        paddingLeftPx = 8.0, paddingTopPx = 6.0, paddingRightPx = 8.0,
      ),
      0.0,
    )
  }

  @Test
  fun paddedEditorKeepsCommittedGlyphOriginInBothDirections() {
    val ltr = textEditorFrameBounds(
      PageRect(100.0, 20.0, 180.0, 44.0), false, 4.0, 3.0, 4.0,
    )
    assertEquals(100.0, ltr.left + 4.0, 0.0)
    assertEquals(20.0, ltr.top + 3.0, 0.0)

    val rtl = textEditorFrameBounds(
      PageRect(100.0, 20.0, 180.0, 44.0), true, 4.0, 3.0, 4.0,
    )
    assertEquals(180.0, rtl.right - 4.0, 0.0)
    assertEquals(20.0, rtl.top + 3.0, 0.0)
  }

  @Test
  fun directionResolutionUsesTheFirstStrongCharacter() {
    assertTrue(textIsRtl("123 العربية"))
    assertTrue(!textIsRtl("123 English"))
  }

  @Test
  fun activeSelectionVisibilityFollowsTheEndpointThatChanged() {
    assertEquals(
      9,
      activeSelectionOffsetAfterChange(2, 8, 2, 2, 9),
    )
    assertEquals(
      1,
      activeSelectionOffsetAfterChange(2, 8, 8, 1, 8),
    )
    assertEquals(
      12,
      activeSelectionOffsetAfterChange(2, 8, 8, 0, 12),
    )
    assertEquals(
      5,
      activeSelectionOffsetAfterChange(5, 5, 5, 5, 5),
    )
  }

  @Test
  fun emptyEditorCanRetainItsPreviousDirection() {
    assertTrue(textDirectionIsRtl("", emptyDirectionRtl = true))
    assertTrue(!textDirectionIsRtl("", emptyDirectionRtl = false))
    assertTrue(textDirectionIsRtl("123 العربية", emptyDirectionRtl = false))
  }

  @Test
  fun keyboardLanguageIsOnlyAnInitialDirectionHint() {
    assertEquals(true, inputLanguageDirectionHint("he-IL"))
    assertEquals(false, inputLanguageDirectionHint("en-US"))
    assertEquals(null, inputLanguageDirectionHint(null))
    assertEquals(null, inputLanguageDirectionHint("und"))
    assertTrue(textDirectionIsRtl("עברית", inputLanguageDirectionHint("en-US")))
    assertTrue(!textDirectionIsRtl("English", inputLanguageDirectionHint("he-IL")))
    assertTrue(textDirectionIsRtl("", emptyDirectionRtl = true))
  }

  @Test
  fun materializedSoftWrapsAreExplicitAndIdempotent() {
    val text = "firstsecond"
    val wrapped = materializeSoftWraps(
      text,
      lineStarts = listOf(0, 5),
      lineEnds = listOf(5, text.length),
    )

    assertEquals("first\nsecond", wrapped)
    assertEquals(
      wrapped,
      materializeSoftWraps(
        wrapped,
        lineStarts = listOf(0, 6),
        lineEnds = listOf(6, wrapped.length),
      ),
    )
    assertEquals(
      "first\nsecond",
      materializeSoftWraps(
        "first\nsecond",
        lineStarts = listOf(0, 6),
        lineEnds = listOf(6, 12),
      ),
    )
  }

  @Test
  fun imeOcclusionUsesOnlyTheOverlapWithThePdfView() {
    assertEquals(
      100.0,
      localImeOverlapPx(
        viewTopInWindow = 200,
        viewHeight = 500,
        rootTopInWindow = 0,
        rootHeight = 800,
        imeBottomInset = 200,
      ),
      0.0,
    )
    assertEquals(
      0.0,
      localImeOverlapPx(
        viewTopInWindow = 100,
        viewHeight = 400,
        rootTopInWindow = 0,
        rootHeight = 800,
        imeBottomInset = 200,
      ),
      0.0,
    )
    assertEquals(
      300.0,
      localImeOverlapPx(
        viewTopInWindow = 400,
        viewHeight = 300,
        rootTopInWindow = 100,
        rootHeight = 600,
        imeBottomInset = 400,
      ),
      0.0,
    )
  }

  private fun text(
    id: String,
    value: String,
    left: Double,
    top: Double,
    fontSize: Double = 16.0,
  ) = TextAnnotation(
    id = id,
    text = value,
    bounds = PageRect(left, top, left + 40.0, top + 18.0),
    fontSize = fontSize,
  )
}
