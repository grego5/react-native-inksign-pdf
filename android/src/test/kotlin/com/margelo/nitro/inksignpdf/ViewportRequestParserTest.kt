package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Test

class ViewportRequestParserTest {
  @Test
  fun omittedOptionsPreserveAndEmptyOptionsFit() {
    assertEquals(
      ViewportRequest.Preserve,
      ViewportRequestParser.parse(null),
    )
    assertEquals(
      ViewportRequest.Fit,
      ViewportRequestParser.parse(ViewportOptions(null, null, null)),
    )
  }

  @Test
  fun openDefaultsToFitAndExplicitViewportOptsOut() {
    val defaultViewport = ViewportRequestParser.parseOpen(null)
    assertEquals(true, defaultViewport.fitToPage)
    assertEquals(null, defaultViewport.zoom)

    val emptyViewport = ViewportRequestParser.parseOpen(
      ViewportOptions(null, null, null),
    )
    assertEquals(true, emptyViewport.fitToPage)

    val explicitViewport = ViewportRequestParser.parseOpen(
      ViewportOptions(10.0, 20.0, 0.8),
    )
    assertEquals(false, explicitViewport.fitToPage)
    assertEquals(0.8, explicitViewport.zoom)
  }

  @Test
  fun zoomOnlyAndPairedCoordinatesBecomeExplicitRequests() {
    assertEquals(
      ViewportRequest.FocusAndZoom(focus = null, zoom = 2.0),
      ViewportRequestParser.parse(ViewportOptions(null, null, 2.0)),
    )
    assertEquals(
      ViewportRequest.FocusAndZoom(
        focus = PagePoint(10.0, 20.0),
        zoom = null,
      ),
      ViewportRequestParser.parse(ViewportOptions(10.0, 20.0, null)),
    )
  }

}
