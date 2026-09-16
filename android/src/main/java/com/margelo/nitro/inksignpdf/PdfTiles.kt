package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

internal const val androidPdfTileSizePx = 512
internal const val androidPdfTileVisiblePriority = 0
internal const val androidPdfTilePrefetchPriority = 1
private const val tileScaleRoot = 1.4142135623730951
private val tileScaleLog = ln(tileScaleRoot)

internal data class PdfTileKey(
  val generation: Long,
  val pageSwitchId: Long,
  val pageIndex: Int,
  val level: Int,
  val x: Int,
  val y: Int,
)

internal data class PdfTileRequest(
  val key: PdfTileKey,
  val leftPx: Int,
  val topPx: Int,
  val widthPx: Int,
  val heightPx: Int,
  val scale: Double,
  val priority: Int = androidPdfTilePrefetchPriority,
)

internal data class PdfTile(
  val request: PdfTileRequest,
  val bitmap: Bitmap,
) {
  val byteCount: Long
    get() = bitmap.allocationByteCount.toLong()
}

/** Quantized viewport tile window; equality lets the UI skip unchanged work. */
internal data class PdfTileWindow(
  val generation: Long,
  val pageSwitchId: Long,
  val pageIndex: Int,
  val level: Int,
  val scale: Double,
  val pageWidthPx: Int,
  val pageHeightPx: Int,
  val columns: Int,
  val rows: Int,
  val firstColumn: Int,
  val lastColumn: Int,
  val firstRow: Int,
  val lastRow: Int,
  val firstVisibleColumn: Int,
  val lastVisibleColumn: Int,
  val firstVisibleRow: Int,
  val lastVisibleRow: Int,
) {
  fun contains(key: PdfTileKey): Boolean {
    return key.generation == generation && key.pageSwitchId == pageSwitchId &&
      key.pageIndex == pageIndex && key.level == level &&
      key.x in firstColumn..lastColumn && key.y in firstRow..lastRow
  }

  fun matches(
    generation: Long,
    pageSwitchId: Long,
    pageIndex: Int,
    level: Int,
    scale: Double,
    pageWidthPx: Int,
    pageHeightPx: Int,
    columns: Int,
    rows: Int,
    firstColumn: Int,
    lastColumn: Int,
    firstRow: Int,
    lastRow: Int,
    firstVisibleColumn: Int,
    lastVisibleColumn: Int,
    firstVisibleRow: Int,
    lastVisibleRow: Int,
  ): Boolean {
    return this.generation == generation && this.pageSwitchId == pageSwitchId &&
      this.pageIndex == pageIndex && this.level == level && this.scale == scale &&
      this.pageWidthPx == pageWidthPx && this.pageHeightPx == pageHeightPx &&
      this.columns == columns && this.rows == rows && this.firstColumn == firstColumn &&
      this.lastColumn == lastColumn && this.firstRow == firstRow && this.lastRow == lastRow &&
      this.firstVisibleColumn == firstVisibleColumn &&
      this.lastVisibleColumn == lastVisibleColumn &&
      this.firstVisibleRow == firstVisibleRow && this.lastVisibleRow == lastVisibleRow
  }
}

internal fun quantizePdfTileScale(pixelsPerPagePoint: Double): Pair<Int, Double> {
  require(pixelsPerPagePoint.isFinite() && pixelsPerPagePoint > 0.0)
  val level = (ln(pixelsPerPagePoint) / tileScaleLog).roundToInt()
  return level to tileScaleRoot.pow(level.toDouble())
}

/** Computes only the tiles that can contribute to the viewport plus one-tile margin. */
internal object PdfTileGrid {
  fun visibleWindow(
    page: PdfPageDimensions,
    viewport: PageViewport,
    generation: Long,
    pageSwitchId: Long,
    pageIndex: Int,
    topLeft: MutablePagePoint = MutablePagePoint(),
    bottomRight: MutablePagePoint = MutablePagePoint(),
    previous: PdfTileWindow? = null,
  ): PdfTileWindow? {
    val size = viewport.size
    if (size.widthPx <= 0.0 || size.heightPx <= 0.0) return null

    val pixelsPerPagePoint = viewport.zoom * size.density
    val level = (ln(pixelsPerPagePoint) / tileScaleLog).roundToInt()
    val scale = tileScaleRoot.pow(level.toDouble())
    val pageWidthPx = scaledPageLength(page.width, scale)
    val pageHeightPx = scaledPageLength(page.height, scale)
    val columns = tileCount(pageWidthPx)
    val rows = tileCount(pageHeightPx)

    viewport.viewToPage(0.0, 0.0, topLeft)
    viewport.viewToPage(size.widthPx, size.heightPx, bottomRight)
    val visibleLeftPx = floor(min(topLeft.x, bottomRight.x).coerceIn(0.0, page.width) * scale)
    val visibleTopPx = floor(min(topLeft.y, bottomRight.y).coerceIn(0.0, page.height) * scale)
    val visibleRightPx = ceil(maxOf(topLeft.x, bottomRight.x).coerceIn(0.0, page.width) * scale)
    val visibleBottomPx = ceil(maxOf(topLeft.y, bottomRight.y).coerceIn(0.0, page.height) * scale)

    val firstVisibleColumn = tileIndex(visibleLeftPx.toLong(), columns)
    val lastVisibleColumn = tileIndex(
      maxOf(visibleRightPx.toLong() - 1L, visibleLeftPx.toLong()), columns,
    )
    val firstVisibleRow = tileIndex(visibleTopPx.toLong(), rows)
    val lastVisibleRow = tileIndex(
      maxOf(visibleBottomPx.toLong() - 1L, visibleTopPx.toLong()), rows,
    )
    val firstColumn = (firstVisibleColumn - 1).coerceAtLeast(0)
    val lastColumn = (lastVisibleColumn + 1).coerceAtMost(columns - 1)
    val firstRow = (firstVisibleRow - 1).coerceAtLeast(0)
    val lastRow = (lastVisibleRow + 1).coerceAtMost(rows - 1)
    if (previous?.matches(
        generation = generation,
        pageSwitchId = pageSwitchId,
        pageIndex = pageIndex,
        level = level,
        scale = scale,
        pageWidthPx = pageWidthPx,
        pageHeightPx = pageHeightPx,
        columns = columns,
        rows = rows,
        firstColumn = firstColumn,
        lastColumn = lastColumn,
        firstRow = firstRow,
        lastRow = lastRow,
        firstVisibleColumn = firstVisibleColumn,
        lastVisibleColumn = lastVisibleColumn,
        firstVisibleRow = firstVisibleRow,
        lastVisibleRow = lastVisibleRow,
      ) == true
    ) {
      return previous
    }
    return PdfTileWindow(
      generation = generation,
      pageSwitchId = pageSwitchId,
      pageIndex = pageIndex,
      level = level,
      scale = scale,
      pageWidthPx = pageWidthPx,
      pageHeightPx = pageHeightPx,
      columns = columns,
      rows = rows,
      firstColumn = firstColumn,
      lastColumn = lastColumn,
      firstRow = firstRow,
      lastRow = lastRow,
      firstVisibleColumn = firstVisibleColumn,
      lastVisibleColumn = lastVisibleColumn,
      firstVisibleRow = firstVisibleRow,
      lastVisibleRow = lastVisibleRow,
    )
  }

  fun requests(window: PdfTileWindow): List<PdfTileRequest> {
    val requests = ArrayList<PdfTileRequest>(
      (window.lastColumn - window.firstColumn + 1) *
        (window.lastRow - window.firstRow + 1),
    )
    fun append(x: Int, y: Int) {
        val leftPx = x * androidPdfTileSizePx
        val topPx = y * androidPdfTileSizePx
        requests += PdfTileRequest(
          key = PdfTileKey(
            generation = window.generation,
            pageSwitchId = window.pageSwitchId,
            pageIndex = window.pageIndex,
            level = window.level,
            x = x,
            y = y,
          ),
          leftPx = leftPx,
          topPx = topPx,
          widthPx = min(androidPdfTileSizePx, window.pageWidthPx - leftPx),
          heightPx = min(androidPdfTileSizePx, window.pageHeightPx - topPx),
          scale = window.scale,
          priority = if (
            x in window.firstVisibleColumn..window.lastVisibleColumn &&
            y in window.firstVisibleRow..window.lastVisibleRow
          ) androidPdfTileVisiblePriority else androidPdfTilePrefetchPriority,
        )
    }
    for (y in window.firstVisibleRow..window.lastVisibleRow) {
      for (x in window.firstVisibleColumn..window.lastVisibleColumn) append(x, y)
    }
    for (y in window.firstRow..window.lastRow) {
      for (x in window.firstColumn..window.lastColumn) {
        if (x !in window.firstVisibleColumn..window.lastVisibleColumn ||
          y !in window.firstVisibleRow..window.lastVisibleRow
        ) append(x, y)
      }
    }
    return requests
  }

  private fun scaledPageLength(length: Double, scale: Double): Int {
    val scaled = ceil(length * scale)
    if (!scaled.isFinite()) return Int.MAX_VALUE
    return scaled.toLong().coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
  }

  private fun tileCount(lengthPx: Int): Int {
    return ((lengthPx.toLong() + androidPdfTileSizePx - 1L) / androidPdfTileSizePx).toInt()
  }

  private fun tileIndex(pixel: Long, count: Int): Int {
    return (pixel / androidPdfTileSizePx).toInt().coerceIn(0, count - 1)
  }
}

/** UI-owned access-ordered cache. Every bitmap inserted here is released here. */
internal class PdfTileCache(
  private val maxBytes: Long,
) {
  private val entries = LinkedHashMap<PdfTileKey, PdfTile>(16, 0.75f, true)
  private var currentBytes = 0L

  init {
    require(maxBytes > 0L)
  }

  operator fun get(key: PdfTileKey): PdfTile? = entries[key]

  /** Checks presence without changing access order. */
  internal fun containsKey(key: PdfTileKey): Boolean = entries.containsKey(key)

  /**
   * Inserts a tile while keeping the current visible set resident.
   *
   * Returns false when an unprotected tile cannot fit without evicting a
   * protected tile. A rejected tile is recycled by this cache.
   */
  fun put(tile: PdfTile, protectedKeys: Set<PdfTileKey>): Boolean {
    val old = entries.remove(tile.request.key)
    if (old != null) {
      currentBytes -= old.byteCount
      old.bitmap.recycle()
    }
    entries[tile.request.key] = tile
    currentBytes += tile.byteCount
    trimToLimit(protectedKeys)
    return tile.request.key in entries
  }

  fun clear() {
    entries.values.forEach { it.bitmap.recycle() }
    entries.clear()
    currentBytes = 0L
  }

  /** Evicts the oldest unprotected entries until the soft limit is restored. */
  internal fun trimToLimit(protectedKeys: Set<PdfTileKey>) {
    if (currentBytes <= maxBytes) return
    val iterator = entries.entries.iterator()
    while (currentBytes > maxBytes && iterator.hasNext()) {
      val entry = iterator.next()
      if (entry.key in protectedKeys) continue
      currentBytes -= entry.value.byteCount
      entry.value.bitmap.recycle()
      iterator.remove()
    }
  }
}
