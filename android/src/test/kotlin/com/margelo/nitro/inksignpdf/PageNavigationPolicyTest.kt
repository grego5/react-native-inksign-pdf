package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PageNavigationPolicyTest {
  @Test
  fun onlyDownAtTheCorrespondingBoundaryIsEligible() {
    val previous = gesture(pageIndex = 1, focusX = 200.0)
    val next = gesture(pageIndex = 1, focusX = 800.0)

    assertEquals("previous eligibility", NavigationDirection.PREVIOUS, direction(previous, 340.0))
    assertEquals("next eligibility ${next.eligibility}", NavigationDirection.NEXT, direction(next, 0.0))
  }

  @Test
  fun fittedPageAllowsBothDirectionsOnlyWhenNeighborsExist() {
    val first = gesture(pageIndex = 0, pageCount = 2, visibleWidth = 1_000.0, focusX = 500.0)
    val last = gesture(pageIndex = 1, pageCount = 2, visibleWidth = 1_000.0, focusX = 500.0)
    val only = gesture(pageIndex = 0, pageCount = 1, visibleWidth = 1_000.0, focusX = 500.0)

    assertEquals("first next ${first.eligibility}", NavigationDirection.NEXT, direction(first, 0.0))
    assertEquals("last previous", NavigationDirection.PREVIOUS, direction(last, 540.0))
    assertNull(direction(only, 460.0))
  }

  @Test
  fun thresholdAndVerticalDominanceDoNotNavigate() {
    val state = gesture(pageIndex = 1, focusX = 200.0)

    assertNull("dead zone", direction(state, 115.0))
    assertNull(PageNavigationPolicy.direction(state, 340.0, 400.0))
  }

  @Test
  fun eligibilityIsNotRecomputedAfterTheDownEvent() {
    val state = gesture(pageIndex = 1, focusX = 200.0)

    assertEquals(
      NavigationDirection.PREVIOUS,
      PageNavigationPolicy.direction(state, 660.0, 100.0),
    )
  }

  @Test
  fun armCrossingOnlyChangesPresentationStateUntilRelease() {
    val state = gesture(pageIndex = 1, focusX = 800.0, viewportWidthPx = 800.0)
    val updated = PageNavigationPolicy.update(state, -160.0, 100.0)

    assertEquals(SwipePhase.ARMED, updated.phase)
    assertEquals(1, updated.targetDelta)
    assertEquals(-80.0, updated.presentationOffsetPx, 0.0000001)
    assertEquals(0.96, updated.presentationScale, 0.0000001)
  }

  @Test
  fun rtlReversesPhysicalDirectionWithoutChangingNumericTargetMeaning() {
    val nextState = gesture(pageIndex = 1, focusX = 200.0, isRtl = true)
    val previousState = gesture(pageIndex = 1, focusX = 800.0, isRtl = true)

    assertEquals(NavigationDirection.NEXT, direction(nextState, 340.0))
    assertEquals(NavigationDirection.PREVIOUS,
      PageNavigationPolicy.direction(previousState, -140.0, 100.0))
  }

  @Test
  fun armDistanceIsThirtyPercentOfTheVisiblePageWidthWithoutFixedClamps() {
    val state = gesture(
      pageIndex = 1,
      pageWidth = 2_000.0,
      focusX = 1_000.0,
      visibleWidth = 1_000.0,
      viewportWidthPx = 3_000.0,
    )

    assertEquals(600.0, state.armDistancePx, 0.0000001)
  }

  private fun gesture(
    pageIndex: Int,
    pageCount: Int = 3,
    pageWidth: Double = 1_000.0,
    focusX: Double,
    visibleWidth: Double = 400.0,
    viewportWidthPx: Double = 800.0,
    isRtl: Boolean = false,
  ): NavigationGesture {
    return requireNotNull(
      PageNavigationPolicy.capture(
        downX = 100.0,
        downY = 100.0,
        density = 2.0,
        pageIndex = pageIndex,
        pageCount = pageCount,
        pageWidth = pageWidth,
        focusX = focusX,
        visibleWidth = visibleWidth,
        zoom = 1.0,
        viewportWidthPx = viewportWidthPx,
        isRtl = isRtl,
      ),
    )
  }

  private fun direction(
    state: NavigationGesture,
    currentX: Double,
  ): NavigationDirection? {
    return PageNavigationPolicy.direction(state, currentX, 100.0)
  }
}
