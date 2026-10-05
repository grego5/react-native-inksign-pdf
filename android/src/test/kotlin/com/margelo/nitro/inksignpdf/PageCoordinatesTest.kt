package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Test

class PageCoordinatesTest {
  @Test
  fun quarterTurnTransformsRoundTripContentPointsAndRectangles() {
    val cases = listOf(
      Triple(PdfPageDimensions(320.0, 240.0, 0), PagePoint(0.0, 0.0), PagePoint(0.0, 0.0)),
      Triple(PdfPageDimensions(240.0, 320.0, 1), PagePoint(0.0, 0.0), PagePoint(240.0, 0.0)),
      Triple(PdfPageDimensions(320.0, 240.0, 2), PagePoint(0.0, 0.0), PagePoint(320.0, 240.0)),
      Triple(PdfPageDimensions(240.0, 320.0, 3), PagePoint(0.0, 0.0), PagePoint(0.0, 320.0)),
    )
    val rawRect = PageRect(10.0, 20.0, 60.0, 40.0)

    cases.forEach { (page, rawOrigin, expectedDisplayOrigin) ->
      val coordinates = PageCoordinates(page)
      assertEquals(expectedDisplayOrigin, coordinates.rawToDisplay(rawOrigin))
      assertEquals(rawOrigin, coordinates.displayToRaw(expectedDisplayOrigin))
      assertEquals(rawRect, coordinates.displayToRaw(coordinates.rawToDisplay(rawRect)))
    }
  }

  @Test
  fun historyTransformComposesPageRotationWithViewportMapping() {
    val coordinates = PageCoordinates(PdfPageDimensions(240.0, 320.0, rotation = 1))
    val displayToView = PageTransform(2.0, 0.0, 0.0, 2.0, 5.0, 7.0)

    assertEquals(
      ViewPoint(485.0, 7.0),
      coordinates.rawToView(displayToView).map(PagePoint(0.0, 0.0)),
    )
  }
}
