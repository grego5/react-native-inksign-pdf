package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
      id = 1L,
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
    val before = text(1L, "Hello", 24.0, 30.0)
    val after = text(1L, "Hello\nworld", 60.0, 48.0, 18.0)

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
      history.appendText(text(1L, "", 0.0, 0.0))
    }

    assertTrue(rejected.isFailure)
    assertTrue(history.contentSnapshot().isEmpty())
  }

  @Test
  fun unchangedExistingTextDismissalDoesNotCreateAHistoryMutation() {
    val history = InkHistory()
    val annotation = text(1L, "Hello", 24.0, 30.0)
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
    val before = text(1L, "Hello", 24.0, 30.0)
    val after = text(1L, "Updated", 24.0, 30.0)

    assertEquals(TextEditingMutation.Append(after), settleTextEditing(null, after))
    assertEquals(TextEditingMutation.Replace(before, after), settleTextEditing(before, after))
    assertEquals(TextEditingMutation.Remove(before), settleTextEditing(before, null))
    assertEquals(TextEditingMutation.NoOp, settleTextEditing(null, null))
  }

  @Test
  fun emptyTextEditorMinimumContentWidthIsOneEmAndPlacementCentersAboveTap() {
    val size = TextIntrinsicSize(textEditorMinimumContentWidth(16.0), 20.0)
    val placement = chooseTextPlacementPosition(
      PagePoint(150.0, 150.0),
      size,
      page = PdfPageDimensions(300.0, 300.0),
      horizontalPadding = 6.0,
      verticalPadding = 4.0,
    )

    assertEquals(16.0, size.width, 0.0)
    assertTrue(size.height > 0.0)
    assertEquals(150.0, placement.x + size.width / 2.0, 0.0)
    assertEquals(150.0, placement.y + size.height, 0.0)
  }

  @Test
  fun placementClampsTheVisibleFrameAndKeepsItsContentAnchorAligned() {
    val page = PdfPageDimensions(300.0, 300.0)
    val size = TextIntrinsicSize(16.0, 20.0)

    val atLeftEdge = chooseTextPlacementPosition(
      PagePoint(2.0, 3.0), size, page, 6.0, 4.0,
    )
    val leftFrame = textEditorFrameBounds(
      PageRect(
        atLeftEdge.x,
        atLeftEdge.y,
        atLeftEdge.x + size.width,
        atLeftEdge.y + size.height,
      ),
      6.0,
      4.0,
      6.0,
    )
    assertEquals(0.0, leftFrame.left, 0.0)
    assertEquals(0.0, leftFrame.top, 0.0)
    assertEquals(6.0, atLeftEdge.x, 0.0)
    assertEquals(4.0, atLeftEdge.y, 0.0)

    val atRightEdge = chooseTextPlacementPosition(
      PagePoint(298.0, 297.0), size, page, 6.0, 4.0,
    )
    val rightFrame = textEditorFrameBounds(
      PageRect(
        atRightEdge.x,
        atRightEdge.y,
        atRightEdge.x + size.width,
        atRightEdge.y + size.height,
      ),
      6.0,
      4.0,
      6.0,
    )
    assertEquals(300.0, rightFrame.right, 0.0)
    assertEquals(300.0, rightFrame.bottom, 0.0)
    assertEquals(294.0, atRightEdge.x + size.width, 0.0)
    assertEquals(276.0, atRightEdge.y, 0.0)
  }

  @Test
  fun textPlacementSnapsOnlyNearCandidatesWithinTheirSpanAtAnyZoom() {
    val candidate = PdfiumHorizontalSnapCandidate(left = 60.0, right = 240.0, y = 180.0)
    val transform = PageTransform(3.0, 0.0, 0.0, 3.0, 12.0, 24.0)

    assertEquals(
      candidate,
      nearestTextSnapCandidate(
        PagePoint(150.0, 176.0),
        transform,
        listOf(candidate),
        maximumDistancePx = 12.0,
      ),
    )
    assertEquals(
      null,
      nearestTextSnapCandidate(
        PagePoint(150.0, 175.0),
        transform,
        listOf(candidate),
        maximumDistancePx = 12.0,
      ),
    )
    assertEquals(
      null,
      nearestTextSnapCandidate(
        PagePoint(241.0, 179.0),
        transform,
        listOf(candidate),
        maximumDistancePx = 12.0,
      ),
    )
  }

  @Test
  fun keyInsertionSkipsEarlierNameWithoutRuleBeforeApplyingOccurrence() {
    val matches = listOf(
      PdfiumTextKeyMatch(10.0, 10.0, 20.0, 20.0, 0.0, 15.0, 10.0),
      PdfiumTextKeyMatch(10.0, 30.0, 20.0, 40.0, 8.0, 35.0, 10.0),
      PdfiumTextKeyMatch(10.0, 50.0, 20.0, 60.0, 16.0, 55.0, 10.0),
    )
    val rules = listOf(
      PdfiumHorizontalSnapCandidate(25.0, 100.0, 40.0),
      PdfiumHorizontalSnapCandidate(25.0, 100.0, 60.0),
    )
    val page = PdfPageDimensions(120.0, 120.0)

    val first = selectPdfiumTextKeyPlacement(
      matches, rules, TextKeyOccurrence.FIRST, directionRtl = false, page = page,
    )
    assertEquals(8.0, first?.match?.sourceIndex)
    assertEquals(rules[0], first?.rule)
    val last = selectPdfiumTextKeyPlacement(
      matches, rules, TextKeyOccurrence.LAST, directionRtl = false, page = page,
    )
    assertEquals(16.0, last?.match?.sourceIndex)
    assertEquals(rules[1], last?.rule)
    assertNull(selectPdfiumTextKeyPlacement(
      listOf(matches.first().copy(lineHeight = 0.0)),
      emptyList(),
      TextKeyOccurrence.FIRST,
      directionRtl = false,
      page = page,
    ))
  }

  @Test
  fun keyUnderlineRuleLeavesTheLabelAndMarginOutsideTheTextFlow() {
    val match = PdfiumTextKeyMatch(40.0, 20.0, 60.0, 30.0, 0.0, 25.0, 10.0)
    val page = PdfPageDimensions(120.0, 120.0)
    val ltrRule = PdfiumHorizontalSnapCandidate(50.0, 100.0, 25.0)
    val rtlRule = PdfiumHorizontalSnapCandidate(0.0, 50.0, 25.0)

    val ltr = selectPdfiumTextKeyPlacement(
      listOf(match), listOf(ltrRule), TextKeyOccurrence.FIRST, directionRtl = false, page = page,
    )
    assertEquals(62.0, ltr?.contentLeft)
    assertEquals(100.0, ltr?.contentRight)

    val rtl = selectPdfiumTextKeyPlacement(
      listOf(match), listOf(rtlRule), TextKeyOccurrence.FIRST, directionRtl = true, page = page,
    )
    assertEquals(0.0, rtl?.contentLeft)
    assertEquals(38.0, rtl?.contentRight)
  }

  @Test
  fun annotationOuterGeometryMatchesTheEditorFrameAtEveryZoomAndDirection() {
    val content = PageRect(100.0, 40.0, 180.0, 64.0)
    for (scale in listOf(1.0, 2.0, 7.0)) {
      val transform = PageTransform(scale, 0.0, 0.0, scale, 13.0, 21.0)
      val fontSizePx = 16.0 * scale
      val horizontalPaddingPx = textEditorPaddingPx(
        fontSizePx,
        textEditorHorizontalPaddingRatio,
      ).toFloat()
      val verticalPaddingPx = textEditorPaddingPx(
        fontSizePx,
        textEditorVerticalPaddingRatio,
      ).toFloat()
      val outer = textAnnotationOuterBounds(
        content,
        transform,
        horizontalPaddingPx.toDouble(),
        verticalPaddingPx.toDouble(),
      )

      for (isRtl in listOf(false, true)) {
        val anchor = if (isRtl) content.right else content.left
        val editorContent = textEditorPageBounds(
          anchor,
          content.top,
          TextIntrinsicSize(content.right - content.left, content.bottom - content.top),
          isRtl,
        )
        val frame = textEditorFrameBounds(
          editorContent,
          horizontalPaddingPx / scale,
          verticalPaddingPx / scale,
          horizontalPaddingPx / scale,
        )
        val mappedTopLeft = transform.map(PagePoint(frame.left, frame.top))
        val mappedBottomRight = transform.map(PagePoint(frame.right, frame.bottom))
        assertEquals(mappedTopLeft.x, outer.left, 0.01)
        assertEquals(mappedTopLeft.y, outer.top, 0.01)
        assertEquals(mappedBottomRight.x, outer.right, 0.01)
        assertEquals(mappedBottomRight.y, outer.bottom, 0.01)
      }
    }
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
      PageRect(100.0, 20.0, 180.0, 44.0), 4.0, 3.0, 4.0,
    )
    assertEquals(100.0, ltr.left + 4.0, 0.0)
    assertEquals(180.0, ltr.right - 4.0, 0.0)
    assertEquals(20.0, ltr.top + 3.0, 0.0)
    assertEquals(44.0, ltr.bottom - 3.0, 0.0)

    val rtl = textEditorFrameBounds(
      PageRect(100.0, 20.0, 180.0, 44.0), 4.0, 3.0, 4.0,
    )
    assertEquals(180.0, rtl.right - 4.0, 0.0)
    assertEquals(20.0, rtl.top + 3.0, 0.0)
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
    id: Long,
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
