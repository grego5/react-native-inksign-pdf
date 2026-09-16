package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LowLatencyInkDirtyRegionTest {
  private val identity = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

  @Test
  fun replacementUnionsPreviousAndCurrentPredictionWithAntialiasOutset() {
    val previous = LowLatencyInkBoundsSnapshot(
      liveTail = InkBounds(10f, 10f, 20f, 20f),
      prediction = InkBounds(30f, 30f, 40f, 40f),
      newlyStable = null,
    )
    val current = LowLatencyInkBoundsSnapshot(
      liveTail = InkBounds(12f, 12f, 22f, 22f),
      prediction = InkBounds(50f, 50f, 60f, 60f),
      newlyStable = InkBounds(8f, 8f, 9f, 9f),
    )

    val region = LowLatencyInkDirtyRegionCalculator.calculate(
      previous = previous,
      current = current,
      transform = identity,
      viewWidth = 100,
      viewHeight = 100,
    )

    assertEquals(InkDirtyRegion(7, 7, 61, 61), region)
  }

  @Test
  fun dirtyRegionIsClippedAndResetCoversTheWholeOverlay() {
    val current = LowLatencyInkBoundsSnapshot(
      liveTail = InkBounds(-20f, -10f, 5f, 6f),
      prediction = null,
      newlyStable = null,
    )
    val clipped = LowLatencyInkDirtyRegionCalculator.calculate(
      previous = null,
      current = current,
      transform = identity,
      viewWidth = 32,
      viewHeight = 24,
    )
    assertEquals(InkDirtyRegion(0, 0, 6, 7), clipped)

    val reset = LowLatencyInkDirtyRegionCalculator.calculate(
      previous = null,
      current = current,
      transform = identity,
      viewWidth = 32,
      viewHeight = 24,
      reset = true,
    )
    assertEquals(InkDirtyRegion(0, 0, 32, 24), reset)
  }

  @Test
  fun noBoundsProducesNoOrdinaryDraw() {
    val empty = LowLatencyInkBoundsSnapshot(null, null, null)
    assertNull(
      LowLatencyInkDirtyRegionCalculator.calculate(
        previous = null,
        current = empty,
        transform = identity,
        viewWidth = 32,
        viewHeight = 24,
      ),
    )
  }
}
