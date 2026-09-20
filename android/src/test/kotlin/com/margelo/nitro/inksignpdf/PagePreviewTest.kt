package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PagePreviewTest {
  @Test
  fun targetPanelStartsOneViewportAwayAndSharesPullTranslation() {
    assertEquals(800.0, targetPanelOffsetX(SwipeDirection.LEFT, 800.0, 0.0), 0.0000001)
    assertEquals(-800.0, targetPanelOffsetX(SwipeDirection.RIGHT, 800.0, 0.0), 0.0000001)
    assertEquals(760.0, targetPanelOffsetX(SwipeDirection.LEFT, 800.0, -40.0), 0.0000001)
    assertEquals(-760.0, targetPanelOffsetX(SwipeDirection.RIGHT, 800.0, 40.0), 0.0000001)
  }

  @Test
  fun fitCenteredTargetPreviewIsIndependentOfOutgoingViewport() {
    val targetPage = PdfPageDimensions(600.0, 1_200.0)
    val viewportSize = ViewportSize(800.0, 800.0, 2.0)
    val targetViewport = PageViewport(targetPage, viewportSize)
    val intent = pagePreviewRequest(
      generation = 4L,
      pageSwitchId = 9L,
      sourcePageIndex = 2,
      targetPageIndex = 3,
      direction = SwipeDirection.RIGHT,
      targetPage = targetPage,
      targetZoom = targetViewport.fitZoom(),
      targetFocus = PagePoint(targetPage.width / 2.0, targetPage.height / 2.0),
      targetContentRevision = 0L,
      viewportWidthPx = 800,
      viewportHeightPx = 800,
      density = 2.0,
      inkPaths = emptyList(),
    )

    val value = requireNotNull(intent)
    assertEquals(targetViewport.fitZoom(), value.key.targetZoom, 0.0000001)
    assertEquals(PagePoint(300.0, 600.0), value.key.targetFocus)
    assertEquals(800.0, value.targetPageRect().left + value.targetPageRect().right, 0.0000001)
    assertEquals(800.0, value.targetPageRect().top + value.targetPageRect().bottom, 0.0000001)
  }

  @Test
  fun intentUsesTargetViewportAndKeepsCommittedInkDetachedFromHistory() {
    val ink = InkPathData.fromCommands(
      listOf(
        InkPathCommand(InkPathCommand.MOVE, x = 10f, y = 20f),
        InkPathCommand(InkPathCommand.LINE, x = 30f, y = 40f),
      ),
    )
    val intent = pagePreviewRequest(
      generation = 4L,
      pageSwitchId = 9L,
      sourcePageIndex = 0,
      targetPageIndex = 1,
      direction = SwipeDirection.LEFT,
      targetPage = PdfPageDimensions(1_000.0, 1_500.0),
      targetZoom = 1.25,
      targetFocus = PagePoint(700.0, 800.0),
      targetContentRevision = 3L,
      viewportWidthPx = 600,
      viewportHeightPx = 800,
      density = 2.0,
      inkPaths = listOf(ink),
    )

    assertNotNull(intent)
    val value = requireNotNull(intent)
    assertEquals(1.25, value.key.targetZoom, 0.0000001)
    assertEquals(PagePoint(700.0, 800.0), value.key.targetFocus)
    assertEquals(3L, value.key.targetContentRevision)
    assertEquals(600, value.request.widthPx)
    assertEquals(800, value.request.heightPx)
    assertEquals(2.5, value.request.scale, 0.0000001)
    assertEquals(1, value.request.key.pageIndex)
    assertEquals(listOf(ink), value.inkPaths)
  }

  @Test
  fun intentCarriesImmutableCommittedTextAlongsideContentRevision() {
    val text = TextAnnotation(
      id = "text-1",
      text = "שלום\nArabic العربية",
      bounds = PageRect(10.0, 20.0, 180.0, 60.0),
      fontSize = 16.0,
    )
    val intent = pagePreviewRequest(
      generation = 4L,
      pageSwitchId = 9L,
      sourcePageIndex = 0,
      targetPageIndex = 1,
      direction = SwipeDirection.LEFT,
      targetPage = PdfPageDimensions(200.0, 100.0),
      targetZoom = 1.0,
      targetFocus = PagePoint(100.0, 50.0),
      targetContentRevision = 7L,
      viewportWidthPx = 300,
      viewportHeightPx = 300,
      density = 1.0,
      inkPaths = emptyList(),
      textAnnotations = listOf(text),
    )

    val value = requireNotNull(intent)
    assertEquals(7L, value.key.targetContentRevision)
    assertEquals(listOf(text), value.textAnnotations)
  }

  @Test
  fun invalidViewportAndNonFiniteTargetAreRejected() {
    assertNull(pagePreviewRequest(
      generation = 1L,
      pageSwitchId = 1L,
      sourcePageIndex = 0,
      targetPageIndex = 1,
      direction = SwipeDirection.RIGHT,
      targetPage = PdfPageDimensions(100.0, 100.0),
      targetZoom = Double.NaN,
      targetFocus = PagePoint(50.0, 50.0),
      targetContentRevision = 0L,
      viewportWidthPx = 100,
      viewportHeightPx = 100,
      density = 1.0,
      inkPaths = emptyList(),
    ))
    assertNull(pagePreviewRequest(
      generation = 1L,
      pageSwitchId = 1L,
      sourcePageIndex = 0,
      targetPageIndex = 1,
      direction = SwipeDirection.RIGHT,
      targetPage = PdfPageDimensions(100.0, 100.0),
      targetZoom = 1.0,
      targetFocus = PagePoint(50.0, 50.0),
      targetContentRevision = 0L,
      viewportWidthPx = 0,
      viewportHeightPx = 100,
      density = 1.0,
      inkPaths = emptyList(),
    ))
  }
}
