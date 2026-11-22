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

  @Test
  fun canonicalTargetsRoundTripThroughEveryDisplayedRotation() {
    val canonical = PageRect(31.0, 47.0, 92.0, 118.0)
    val cases = listOf(
      PdfPageDimensions(320.0, 240.0, 0),
      PdfPageDimensions(320.0, 240.0, 1),
      PdfPageDimensions(320.0, 240.0, 2),
      PdfPageDimensions(320.0, 240.0, 3),
    )

    cases.forEach { page ->
      val coordinates = PageCoordinates(page)
      assertEquals(canonical, coordinates.displayToCanonical(coordinates.canonicalToDisplay(canonical)))
    }
  }

  @Test
  fun capturedLayoutRotationReturnsToCanonicalBeforeCurrentDisplayProjection() {
    val media = PdfPageDimensions(320.0, 240.0)
    val captured = PdfPageDimensions(240.0, 320.0, rotation = 1)
    val current = PageCoordinates(media.copy(rotation = 3))
    val local = PageRect(22.0, 35.0, 82.0, 115.0)
    val layoutToCanonical = PageCoordinates(media).layoutToCanonical(captured)
    val canonical = textAnnotationOuterBounds(local, layoutToCanonical, 0.0, 0.0)
    val displayed = current.canonicalToDisplay(canonical)

    assertEquals(canonical, current.displayToCanonical(displayed))
    assertEquals(local, textAnnotationOuterBounds(canonical, layoutToCanonical.inverse(), 0.0, 0.0))
  }
}
