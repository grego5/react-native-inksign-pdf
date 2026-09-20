package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PageViewportTest {
  @Test
  fun fitUsesDensityIndependentDimensionsForPortraitPage() {
    val viewport = PageViewport(
      page = PdfPageDimensions(300.0, 400.0),
      initialSize = ViewportSize(600.0, 800.0, density = 2.0),
    )

    assertEquals(1.0, viewport.fitZoom(), epsilon)
    viewport.fit()
    assertEquals(1.0, viewport.zoom, epsilon)
    assertEquals(PagePoint(150.0, 200.0), viewport.focus)
  }

  @Test
  fun fitUsesLandscapeLimitingDimension() {
    val viewport = PageViewport(
      page = PdfPageDimensions(400.0, 300.0),
      initialSize = ViewportSize(1000.0, 800.0, density = 2.0),
    )

    assertEquals(1.25, viewport.fitZoom(), epsilon)
  }

  @Test
  fun omittedFocusCentersThePageAndExplicitFocusIsClamped() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )

    viewport.setZoom(2.0)
    assertEquals(PagePoint(500.0, 400.0), viewport.focus)

    viewport.setFocus(PagePoint(-100.0, 900.0))
    assertEquals(PagePoint(100.0, 725.0), viewport.focus)
  }

  @Test
  fun zoomOnlyViewportRequestPreservesFocus() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.setZoom(1.0, PagePoint(500.0, 400.0))

    viewport.setZoomPreservingFocus(2.0)

    assertEquals(2.0, viewport.zoom, epsilon)
    assertEquals(PagePoint(500.0, 400.0), viewport.focus)
  }

  @Test
  fun doubleTapZoomCalculatesAbsoluteCenteredTargetWithoutMutatingViewport() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.fit()
    val tappedPagePoint = viewport.viewToPage(ViewPoint(100.0, 75.0))

    val target = requireNotNull(viewport.zoomTo(100.0, 75.0, 2.0))
    assertEquals(2.0, target.zoom, epsilon)
    assertEquals(tappedPagePoint, target.focus)
    assertEquals(viewport.fitZoom(), viewport.zoom, epsilon)
    assertEquals(PagePoint(500.0, 400.0), viewport.focus)

    viewport.setViewport(target.zoom, target.focus)
    assertEquals(tappedPagePoint, viewport.viewToPage(ViewPoint(200.0, 150.0)))
    assertTrue(viewport.zoomTo(100.0, 75.0, 2.0) == null)
  }

  @Test
  fun doubleTapTargetClampsEveryEdgeToTheNearestValidViewport() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.fit()

    val cornerTargets = listOf(
      ViewPoint(0.0, 0.0) to PagePoint(100.0, 75.0),
      ViewPoint(400.0, 0.0) to PagePoint(900.0, 75.0),
      ViewPoint(0.0, 300.0) to PagePoint(100.0, 725.0),
      ViewPoint(400.0, 300.0) to PagePoint(900.0, 725.0),
    )

    cornerTargets.forEach { (viewPoint, expectedFocus) ->
      assertEquals(expectedFocus, requireNotNull(
        viewport.zoomTo(viewPoint.x, viewPoint.y, 2.0),
      ).focus)
    }
  }

  @Test
  fun doubleTapTargetCentersDimensionsSmallerThanTheViewport() {
    val viewport = PageViewport(
      page = PdfPageDimensions(100.0, 80.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.setZoom(0.5)

    val target = requireNotNull(viewport.zoomTo(0.0, 0.0, 1.0))

    assertEquals(PagePoint(50.0, 40.0), target.focus)
  }

  @Test
  fun fitStateIsFalseAfterZoomAndTrueAfterFittingAgain() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.fit()
    assertTrue(viewport.isFitted())

    viewport.setZoom(2.0, PagePoint(500.0, 400.0))
    assertTrue(!viewport.isFitted())

    viewport.fit()
    assertTrue(viewport.isFitted())
  }

  @Test
  fun zoomIsClampedAndOneMeansOnePointPerDp() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(600.0, 400.0, density = 3.0),
    )

    viewport.setZoom(-10.0)
    assertEquals(minPageViewportZoom, viewport.zoom, epsilon)
    viewport.setZoom(100.0)
    assertEquals(maxPageViewportZoom, viewport.zoom, epsilon)

    viewport.setZoom(1.0)
    val center = viewport.pageToView(PagePoint(500.0, 400.0))
    assertEquals(ViewPoint(300.0, 200.0), center)
  }

  @Test
  fun pageAndViewTransformsAreInverses() {
    val viewport = PageViewport(
      page = PdfPageDimensions(612.0, 792.0),
      initialSize = ViewportSize(900.0, 1200.0, density = 2.0),
    )
    viewport.setZoom(3.0, PagePoint(222.0, 345.0))

    val pagePoint = PagePoint(400.25, 512.75)
    val viewPoint = viewport.pageToView(pagePoint)
    val roundTrip = viewport.viewToPage(viewPoint)
    assertEquals(pagePoint.x, roundTrip.x, epsilon)
    assertEquals(pagePoint.y, roundTrip.y, epsilon)
    val restored = viewport.state.viewToPage.inverse()
    val expected = viewport.state.pageToView
    assertEquals(expected.a, restored.a, epsilon)
    assertEquals(expected.b, restored.b, epsilon)
    assertEquals(expected.c, restored.c, epsilon)
    assertEquals(expected.d, restored.d, epsilon)
    assertEquals(expected.tx, restored.tx, epsilon)
    assertEquals(expected.ty, restored.ty, epsilon)
  }

  @Test
  fun strokeScaleUsesAverageAffineBasisAndConvertsPixelsToDpOnce() {
    val transform = PageTransform(
      a = 6.0,
      b = 8.0,
      c = -8.0,
      d = 6.0,
      tx = 12.0,
      ty = -4.0,
    )

    assertEquals(10.0, transform.uniformScale()!!, epsilon)
    assertEquals(5.0, transform.logicalDisplayUnitsPerPageUnit(2.0)!!, epsilon)
  }

  @Test
  fun strokeScaleRejectsSingularOrNonUniformAffineBasis() {
    val singular = PageTransform(1.0, 0.0, 2.0, 0.0, 0.0, 0.0)
    assertTrue(singular.uniformScale() == null)

    val nonUniform = PageTransform(10.0, 0.0, 0.0, 9.0, 0.0, 0.0)
    assertTrue(nonUniform.uniformScale() == null)
  }

  @Test
  fun publicDpWidthsBecomeFrozenPageWidthsAtCapturedScale() {
    val pen = PenConfiguration.DEFAULT.inPageUnits(16.0)

    assertEquals(2.0 / 16.0, pen.minWidth, epsilon)
    assertEquals(4.0 / 16.0, pen.maxWidth, epsilon)
  }

  @Test
  fun reusableViewToPageDestinationMatchesAllocatingConversion() {
    val viewport = PageViewport(
      page = PdfPageDimensions(612.0, 792.0),
      initialSize = ViewportSize(900.0, 1200.0, density = 2.0),
    )
    viewport.setZoom(3.0, PagePoint(222.0, 345.0))
    val destination = MutablePagePoint()

    viewport.viewToPage(630.0, 840.0, destination)
    val expected = viewport.viewToPage(ViewPoint(630.0, 840.0))
    assertEquals(expected.x, destination.x, epsilon)
    assertEquals(expected.y, destination.y, epsilon)

    viewport.setZoom(1.5, PagePoint(300.0, 400.0))
    viewport.viewToPage(120.0, 300.0, destination)
    val reusedExpected = viewport.viewToPage(ViewPoint(120.0, 300.0))
    assertEquals(reusedExpected.x, destination.x, epsilon)
    assertEquals(reusedExpected.y, destination.y, epsilon)
  }

  @Test
  fun reusableViewToPageDestinationUsesTheKeyboardAdjustedFrame() {
    val viewport = PageViewport(
      page = PdfPageDimensions(612.0, 792.0),
      initialSize = ViewportSize(900.0, 1200.0, density = 2.0),
    )
    viewport.setZoom(1.5, PagePoint(300.0, 400.0))
    viewport.setBottomInsetPx(240.0)
    val destination = MutablePagePoint()

    viewport.viewToPage(450.0, 480.0, destination)
    val expected = viewport.viewToPage(ViewPoint(450.0, 480.0))

    assertEquals(expected.x, destination.x, epsilon)
    assertEquals(expected.y, destination.y, epsilon)
  }

  @Test
  fun panIsClampedAndNonFiniteInputsDoNotPoisonState() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.setZoom(2.0, PagePoint(500.0, 400.0))

    viewport.panBy(-10_000.0, 10_000.0)
    assertEquals(PagePoint(100.0, 725.0), viewport.focus)

    viewport.setZoom(Double.NaN, PagePoint(Double.POSITIVE_INFINITY, 10.0))
    assertEquals(2.0, viewport.zoom, epsilon)
    assertTrue(viewport.focus.x.isFinite() && viewport.focus.y.isFinite())
    viewport.panBy(Double.NaN, 0.0)
    assertTrue(viewport.pageToView(PagePoint(1.0, 1.0)).x.isFinite())
  }

  @Test
  fun keyboardInsetUsesTopAnchoredUsableFrameAndAllowsBottomFocus() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.setZoom(2.0, PagePoint(500.0, 400.0))
    viewport.setBottomInsetPx(100.0)

    assertEquals(100.0, viewport.pageToView(PagePoint(500.0, 400.0)).y, epsilon)
    assertTrue(viewport.ensurePageRectVisible(450.0, 700.0, 550.0, 760.0, 8.0))
    assertTrue(viewport.focus.y > 400.0)
    assertTrue(viewport.pageToView(PagePoint(550.0, 760.0)).y <= 192.0 + epsilon)
  }

  @Test
  fun keyboardVisibilityDoesNotMoveAlreadyVisibleEditor() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.setZoom(2.0, PagePoint(500.0, 400.0))
    viewport.setBottomInsetPx(100.0)

    val before = viewport.focus
    assertTrue(!viewport.ensurePageRectVisible(450.0, 350.0, 550.0, 450.0, 8.0))
    assertEquals(before, viewport.focus)
  }

  @Test
  fun caretUsesOneMarginWhileKeyboardAdjustmentKeepsHorizontalFocus() {
    val viewport = PageViewport(
      page = PdfPageDimensions(300.0, 300.0),
      initialSize = ViewportSize(300.0, 300.0, density = 1.0),
    )
    viewport.setZoom(1.0, PagePoint(150.0, 150.0))

    assertTrue(viewport.ensurePageRectVisible(2.0, 100.0, 4.0, 120.0, 8.0))
    val horizontalFocus = viewport.focus.x
    assertEquals(8.0, viewport.pageToView(PagePoint(2.0, 110.0)).x, epsilon)

    viewport.setBottomInsetPx(100.0)
    assertTrue(viewport.ensurePageRectVisible(2.0, 260.0, 4.0, 280.0, 8.0))
    assertEquals(horizontalFocus, viewport.focus.x, epsilon)
    assertTrue(viewport.focus.y > 150.0)
  }

  @Test
  fun editEntryTargetKeepsVisibleCaretOrMovesOnlyEnoughToShowIt() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1200.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.setZoom(2.0, PagePoint(600.0, 400.0))

    val visible = viewport.targetForTextEditing(
      editorCenterY = 400.0,
      caret = PageRect(610.0, 390.0, 611.0, 410.0),
      zoom = 2.0,
      paddingPx = 8.0,
    )!!
    assertEquals(600.0, visible.focus.x, epsilon)

    val distant = viewport.targetForTextEditing(
      editorCenterY = 400.0,
      caret = PageRect(1050.0, 390.0, 1051.0, 410.0),
      zoom = 2.0,
      paddingPx = 8.0,
    )!!
    assertTrue(distant.focus.x > visible.focus.x)
    viewport.setViewport(distant.zoom, distant.focus)
    assertEquals(392.0, viewport.pageToView(PagePoint(1051.0, 400.0)).x, epsilon)
  }

  @Test
  fun textLineVisibilityMovesOnlyVerticallyAsNativeCaretScrolls() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.setZoom(2.0, PagePoint(500.0, 400.0))
    viewport.setBottomInsetPx(100.0)
    val originalX = viewport.focus.x

    assertTrue(viewport.ensurePageRectVisible(900.0, 700.0, 901.0, 720.0, 8.0, includeHorizontal = false))
    assertEquals(originalX, viewport.focus.x, epsilon)
    assertTrue(viewport.focus.y > 400.0)
  }

  @Test
  fun caretVisibilityMovesTheSharedViewportOnBothHorizontalSides() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1200.0, 800.0),
      initialSize = ViewportSize(400.0, 300.0, density = 1.0),
    )
    viewport.setZoom(2.0, PagePoint(600.0, 400.0))

    assertTrue(viewport.ensurePageRectVisible(1050.0, 360.0, 1051.0, 380.0, 8.0))
    val rightFocus = viewport.focus.x
    assertTrue(rightFocus > 600.0)

    assertTrue(viewport.ensurePageRectVisible(149.0, 360.0, 150.0, 380.0, 8.0))
    assertTrue(viewport.focus.x < rightFocus)
    assertTrue(viewport.pageToView(PagePoint(150.0, 370.0)).x >= 8.0 - epsilon)
  }

  @Test
  fun caretAtEitherPageEdgeKeepsViewportComfortMargin() {
    val viewport = PageViewport(
      page = PdfPageDimensions(300.0, 300.0),
      initialSize = ViewportSize(300.0, 300.0, density = 1.0),
    )
    viewport.setZoom(1.0, PagePoint(150.0, 150.0))

    assertTrue(viewport.ensurePageRectVisible(-8.0, 100.0, 8.0, 120.0, 8.0))
    assertTrue(viewport.pageToView(PagePoint(0.0, 110.0)).x >= 16.0 - epsilon)
    assertTrue(viewport.ensurePageRectVisible(292.0, 100.0, 308.0, 120.0, 8.0))
    assertTrue(viewport.pageToView(PagePoint(300.0, 110.0)).x <= 300.0 - 16.0 + epsilon)
    viewport.fit()
    assertEquals(150.0, viewport.focus.x, epsilon)
  }

  @Test
  fun keyboardCaretFocusDoesNotJumpBackWhenTheInsetDisappears() {
    val viewport = PageViewport(
      page = PdfPageDimensions(300.0, 300.0),
      initialSize = ViewportSize(300.0, 300.0, density = 1.0),
    )
    viewport.setZoom(1.0, PagePoint(150.0, 150.0))
    viewport.setBottomInsetPx(50.0)

    assertTrue(viewport.ensurePageRectVisible(100.0, 0.0, 200.0, 20.0, 8.0))
    assertTrue(viewport.pageToView(PagePoint(150.0, 0.0)).y >= 8.0 - epsilon)
    val topFocus = viewport.focus.y
    viewport.setBottomInsetPx(0.0)
    assertEquals(topFocus, viewport.focus.y, epsilon)

    viewport.setBottomInsetPx(50.0)
    assertTrue(viewport.ensurePageRectVisible(100.0, 280.0, 200.0, 300.0, 8.0))
    assertTrue(viewport.pageToView(PagePoint(150.0, 300.0)).y <= 250.0 - 8.0 + epsilon)
    val bottomFocus = viewport.focus.y
    viewport.setBottomInsetPx(0.0)
    assertEquals(bottomFocus, viewport.focus.y, epsilon)
    viewport.fit()
    assertEquals(150.0, viewport.focus.y, epsilon)
  }

  private companion object {
    const val epsilon = 0.0000001

    fun assertEquals(expected: ViewPoint, actual: ViewPoint) {
      assertEquals(expected.x, actual.x, epsilon)
      assertEquals(expected.y, actual.y, epsilon)
    }
  }
}
