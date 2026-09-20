package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Test

class PenConfigurationTest {
  @Test
  fun defaultsMatchTheCrossPlatformBaseline() {
    val pen = PenConfiguration.DEFAULT

    assertEquals(2.0, pen.minWidth, epsilon)
    assertEquals(4.0, pen.maxWidth, epsilon)
    assertEquals(0.4, pen.smoothing, epsilon)
  }

  @Test
  fun explicitPublicValuesOverrideDefaultsBeforePageConversion() {
    val pen = PenConfiguration.sanitize(
      color = null,
      minWidth = 3.0,
      maxWidth = 7.0,
      smoothing = 0.8,
    )

    assertEquals(3.0, pen.minWidth, epsilon)
    assertEquals(7.0, pen.maxWidth, epsilon)
    assertEquals(0.8, pen.smoothing, epsilon)

    val pagePen = pen.inPageUnits(2.0)
    assertEquals(1.5, pagePen.minWidth, epsilon)
    assertEquals(3.5, pagePen.maxWidth, epsilon)
    assertEquals(0.8, pagePen.smoothing, epsilon)
  }

  @Test
  fun displayWidthRemainsInvariantAfterConversionAtDifferentScales() {
    val pen = PenConfiguration.DEFAULT
    val firstPagePen = pen.inPageUnits(8.0)
    val secondPagePen = pen.inPageUnits(16.0)

    assertEquals(pen.minWidth, firstPagePen.minWidth * 8.0, epsilon)
    assertEquals(pen.maxWidth, firstPagePen.maxWidth * 8.0, epsilon)
    assertEquals(pen.minWidth, secondPagePen.minWidth * 16.0, epsilon)
    assertEquals(pen.maxWidth, secondPagePen.maxWidth * 16.0, epsilon)
  }

  private companion object {
    const val epsilon = 0.0000001
  }
}
