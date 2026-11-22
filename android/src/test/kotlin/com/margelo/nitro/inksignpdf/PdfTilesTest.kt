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
  fun tileRequestsIncludeTwoTileMarginWithoutFullPageAllocation() {
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

    assertEquals(36, requests.size)
    assertTrue(requests.all { it.key.generation == 9L })
    assertTrue(requests.all { it.key.pageIndex == 1 })
    assertTrue(requests.all { it.widthPx in 1..androidPdfTileSizePx })
    assertTrue(requests.all { it.heightPx in 1..androidPdfTileSizePx })
    assertEquals(setOf(2, 3, 4, 5, 6, 7), requests.map { it.key.x }.toSet())
    assertEquals(setOf(1, 2, 3, 4, 5, 6), requests.map { it.key.y }.toSet())
    assertTrue(requests.take(4).all { it.priority == androidPdfTileVisiblePriority })
    assertTrue(requests.drop(4).all { it.priority == androidPdfTilePrefetchPriority })
  }

  @Test
  fun prefetchMarginClampsAtThePageEdge() {
    val page = PdfPageDimensions(5000.0, 4000.0)
    val viewport = PageViewport(page, ViewportSize(512.0, 512.0, 1.0))
    viewport.setZoom(1.0, PagePoint(256.0, 256.0))
    val window = requireNotNull(PdfTileGrid.visibleWindow(page, viewport, 1L, 1L, 0))
    val requests = PdfTileGrid.requests(window)
    assertEquals(9, requests.size)
    assertEquals(setOf(0, 1, 2), requests.map { it.key.x }.toSet())
    assertEquals(setOf(0, 1, 2), requests.map { it.key.y }.toSet())
    assertEquals(1, requests.count { it.priority == androidPdfTileVisiblePriority })
  }

  @Test
  fun baseRasterPreservesPageProportionsWithinItsPixelBudget() {
    val page = PdfPageDimensions(595.0, 842.0)
    val request = pageBaseRequest(PdfTileKey(1L, 1L, 0, 0, 0, 0), page)
    assertEquals(pageBaseLongestEdgePx, maxOf(request.widthPx, request.heightPx))
    assertEquals(page.width / page.height, request.widthPx.toDouble() / request.heightPx, 0.001)
    assertTrue(request.widthPx.toLong() * request.heightPx <= pageBaseMaxPixels)
    assertEquals(0, request.rasterLeftPx)
    assertEquals(0, request.rasterTopPx)
  }

  @Test
  fun tileRasterBleedIsClampedAndCoreEdgesStayShared() {
    val requests = PdfTileGrid.requests(tileWindow(1200, 1200))
    val topLeft = requests.single { it.key.x == 0 && it.key.y == 0 }
    val topRight = requests.single { it.key.x == 1 && it.key.y == 0 }
    val center = requests.single { it.key.x == 1 && it.key.y == 1 }

    assertEquals(0, topLeft.rasterLeftPx)
    assertEquals(0, topLeft.rasterTopPx)
    assertEquals(514, topLeft.rasterWidthPx)
    assertEquals(514, topLeft.rasterHeightPx)
    assertEquals(topLeft.leftPx + topLeft.widthPx, topRight.leftPx)
    assertEquals(topLeft.leftPx + topLeft.widthPx + androidPdfTileBleedPx,
      topLeft.rasterLeftPx + topLeft.rasterWidthPx)
    assertEquals(topRight.leftPx - androidPdfTileBleedPx, topRight.rasterLeftPx)
    assertEquals(510, center.rasterLeftPx)
    assertEquals(510, center.rasterTopPx)
    assertEquals(516, center.rasterWidthPx)
    assertEquals(516, center.rasterHeightPx)

    val partial = PdfTileGrid.requests(tileWindow(600, 530))
      .single { it.key.x == 1 && it.key.y == 1 }
    assertEquals(88, partial.widthPx)
    assertEquals(18, partial.heightPx)
    assertEquals(510, partial.rasterLeftPx)
    assertEquals(510, partial.rasterTopPx)
    assertEquals(90, partial.rasterWidthPx)
    assertEquals(20, partial.rasterHeightPx)
  }

  @Test
  fun previewRequestKeepsItsUnpaddedRasterBounds() {
    val preview = PdfTileRequest(
      key = PdfTileKey(1L, 2L, 0, 0, 0, 0),
      leftPx = 0,
      topPx = 0,
      widthPx = 320,
      heightPx = 240,
      scale = 0.5,
    )

    assertEquals(0, preview.rasterLeftPx)
    assertEquals(0, preview.rasterTopPx)
    assertEquals(preview.widthPx, preview.rasterWidthPx)
    assertEquals(preview.heightPx, preview.rasterHeightPx)
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

    fun tileWindow(pageWidthPx: Int, pageHeightPx: Int): PdfTileWindow {
      val columns = (pageWidthPx + androidPdfTileSizePx - 1) / androidPdfTileSizePx
      val rows = (pageHeightPx + androidPdfTileSizePx - 1) / androidPdfTileSizePx
      return PdfTileWindow(
        generation = 1L,
        pageSwitchId = 2L,
        pageIndex = 0,
        level = 1,
        scale = 2.0,
        pageWidthPx = pageWidthPx,
        pageHeightPx = pageHeightPx,
        columns = columns,
        rows = rows,
        firstColumn = 0,
        lastColumn = columns - 1,
        firstRow = 0,
        lastRow = rows - 1,
        firstVisibleColumn = 0,
        lastVisibleColumn = columns - 1,
        firstVisibleRow = 0,
        lastVisibleRow = rows - 1,
      )
    }
  }
}
