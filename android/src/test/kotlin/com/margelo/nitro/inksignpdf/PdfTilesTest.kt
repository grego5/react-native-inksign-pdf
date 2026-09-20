package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfTilesTest {
  @Test
  fun pageIdentitySeparatesTileWindowsAndKeys() {
    val page = PdfPageDimensions(5000.0, 4000.0)
    val viewport = PageViewport(
      page = page,
      initialSize = ViewportSize(512.0, 512.0, density = 1.0),
    )
    viewport.setZoom(1.0, PagePoint(2500.0, 2000.0))

    val first = requireNotNull(
      PdfTileGrid.visibleWindow(
        page,
        viewport,
        generation = 9L,
        pageSwitchId = 3L,
        pageIndex = 0,
      ),
    )
    val second = requireNotNull(
      PdfTileGrid.visibleWindow(
        page,
        viewport,
        generation = 9L,
        pageSwitchId = 4L,
        pageIndex = 1,
      ),
    )

    assertNotEquals(first, second)
    assertNotEquals(PdfTileGrid.requests(first).first().key,
      PdfTileGrid.requests(second).first().key)
  }

  @Test
  fun scaleLevelsAreQuantizedToSqrtTwo() {
    val (level, scale) = quantizePdfTileScale(1.0)
    assertEquals(0, level)
    assertEquals(1.0, scale, epsilon)

    val (higherLevel, higherScale) = quantizePdfTileScale(2.0)
    assertEquals(2, higherLevel)
    assertEquals(2.0, higherScale, epsilon)
  }

  @Test
  fun tileRequestsIncludeOneTileMarginWithoutFullPageAllocation() {
    val page = PdfPageDimensions(5000.0, 4000.0)
    val viewport = PageViewport(
      page = page,
      initialSize = ViewportSize(512.0, 512.0, density = 1.0),
    )
    viewport.setZoom(1.0, PagePoint(2500.0, 2000.0))

    val window = requireNotNull(
      PdfTileGrid.visibleWindow(
        page,
        viewport,
        generation = 9L,
        pageSwitchId = 3L,
        pageIndex = 1,
      ),
    )
    val requests = PdfTileGrid.requests(window)

    assertEquals(16, requests.size)
    assertTrue(requests.all { it.key.generation == 9L })
    assertTrue(requests.all { it.key.pageIndex == 1 })
    assertTrue(requests.all { it.widthPx in 1..androidPdfTileSizePx })
    assertTrue(requests.all { it.heightPx in 1..androidPdfTileSizePx })
    assertEquals(setOf(3, 4, 5, 6), requests.map { it.key.x }.toSet())
    assertEquals(setOf(2, 3, 4, 5), requests.map { it.key.y }.toSet())
    assertTrue(requests.take(4).all { it.priority == androidPdfTileVisiblePriority })
    assertTrue(requests.drop(4).all { it.priority == androidPdfTilePrefetchPriority })
  }

  @Test
  fun unchangedViewportWindowReusesPreviousInstance() {
    val page = PdfPageDimensions(5000.0, 4000.0)
    val viewport = PageViewport(
      page = page,
      initialSize = ViewportSize(512.0, 512.0, density = 1.0),
    )
    viewport.setZoom(1.0, PagePoint(2500.0, 2000.0))

    val previous = requireNotNull(
      PdfTileGrid.visibleWindow(
        page,
        viewport,
        generation = 9L,
        pageSwitchId = 3L,
        pageIndex = 1,
      ),
    )
    val reused = PdfTileGrid.visibleWindow(
      page,
      viewport,
      generation = 9L,
      pageSwitchId = 3L,
      pageIndex = 1,
      previous = previous,
    )

    assertSame(previous, reused)
  }

  @Test
  fun zoomAroundKeepsTheFocalPagePointStable() {
    val viewport = PageViewport(
      page = PdfPageDimensions(1000.0, 1000.0),
      initialSize = ViewportSize(500.0, 500.0, density = 1.0),
    )
    val viewPoint = ViewPoint(120.0, 180.0)
    val pagePoint = viewport.viewToPage(viewPoint)

    viewport.zoomAround(viewPoint, 2.0)

    val restored = viewport.pageToView(pagePoint)
    assertEquals(viewPoint.x, restored.x, epsilon)
    assertEquals(viewPoint.y, restored.y, epsilon)
  }

  private companion object {
    const val epsilon = 0.0000001
  }
}
