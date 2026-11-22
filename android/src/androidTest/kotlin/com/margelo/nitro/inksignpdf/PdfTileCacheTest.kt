package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdfTileCacheTest {
  @Test
  fun prefetchCannotEvictVisibleTiles() {
    val firstVisible = tile(1, 0, androidPdfTileVisiblePriority)
    val tileBytes = firstVisible.byteCount
    val secondVisible = tile(2, 0, androidPdfTileVisiblePriority)
    val rejectedPrefetch = tile(3, 0, androidPdfTilePrefetchPriority)
    val evictedPrefetch = tile(0, 0, androidPdfTilePrefetchPriority)
    val cache = PdfTileCache(tileBytes * 2L)

    try {
      val visibleKeys = setOf(firstVisible.request.key, secondVisible.request.key)
      assertTrue(cache.put(evictedPrefetch, visibleKeys))
      assertTrue(cache.put(firstVisible, visibleKeys))
      assertTrue(cache.put(secondVisible, visibleKeys))

      assertFalse(cache.put(rejectedPrefetch, visibleKeys))
      assertNotNull(cache[firstVisible.request.key])
      assertNotNull(cache[secondVisible.request.key])
      assertTrue(evictedPrefetch.bitmap.isRecycled)
      assertTrue(rejectedPrefetch.bitmap.isRecycled)
    } finally {
      cache.clear()
    }
  }

  @Test
  fun fullPrefetchCacheEvictsLeastRecentlyUsedTile() {
    val leastRecentlyUsed = tile(1, 0, androidPdfTilePrefetchPriority)
    val recentlyUsed = tile(2, 0, androidPdfTilePrefetchPriority)
    val replacement = tile(3, 0, androidPdfTilePrefetchPriority)
    val cache = PdfTileCache(leastRecentlyUsed.byteCount * 2L)

    try {
      assertTrue(cache.put(leastRecentlyUsed, emptySet()))
      assertTrue(cache.put(recentlyUsed, emptySet()))
      assertNotNull(cache[recentlyUsed.request.key])

      assertTrue(cache.put(replacement, emptySet()))
      assertNull(cache[leastRecentlyUsed.request.key])
      assertNotNull(cache[recentlyUsed.request.key])
      assertNotNull(cache[replacement.request.key])
      assertTrue(leastRecentlyUsed.bitmap.isRecycled)
      assertFalse(recentlyUsed.bitmap.isRecycled)
      assertFalse(replacement.bitmap.isRecycled)
    } finally {
      cache.clear()
    }
  }

  @Test
  fun presenceCheckDoesNotMakeOldTileRecentlyUsed() {
    val leastRecentlyUsed = tile(1, 0, androidPdfTilePrefetchPriority)
    val recentlyUsed = tile(2, 0, androidPdfTilePrefetchPriority)
    val replacement = tile(3, 0, androidPdfTilePrefetchPriority)
    val cache = PdfTileCache(leastRecentlyUsed.byteCount * 2L)

    try {
      assertTrue(cache.put(leastRecentlyUsed, emptySet()))
      assertTrue(cache.put(recentlyUsed, emptySet()))
      assertTrue(cache.containsKey(leastRecentlyUsed.request.key))

      assertTrue(cache.put(replacement, emptySet()))
      assertTrue(leastRecentlyUsed.bitmap.isRecycled)
      assertNull(cache[leastRecentlyUsed.request.key])
      assertNotNull(cache[recentlyUsed.request.key])
      assertNotNull(cache[replacement.request.key])
    } finally {
      cache.clear()
    }
  }

  @Test
  fun explicitTrimRemovesOldestTileAfterProtectionShrinks() {
    val firstVisible = tile(1, 0, androidPdfTileVisiblePriority)
    val secondVisible = tile(2, 0, androidPdfTileVisiblePriority)
    val cache = PdfTileCache(firstVisible.byteCount)

    try {
      val bothVisible = setOf(firstVisible.request.key, secondVisible.request.key)
      assertTrue(cache.put(firstVisible, bothVisible))
      assertTrue(cache.put(secondVisible, bothVisible))

      cache.trimToLimit(setOf(secondVisible.request.key))

      assertTrue(firstVisible.bitmap.isRecycled)
      assertNull(cache[firstVisible.request.key])
      assertNotNull(cache[secondVisible.request.key])
      assertFalse(secondVisible.bitmap.isRecycled)
    } finally {
      cache.clear()
    }
  }

  @Test
  fun visibleWorkingSetMayExceedSoftLimit() {
    val firstVisible = tile(1, 0, androidPdfTileVisiblePriority)
    val secondVisible = tile(2, 0, androidPdfTileVisiblePriority)
    val cache = PdfTileCache(firstVisible.byteCount)

    try {
      val visibleKeys = setOf(firstVisible.request.key, secondVisible.request.key)
      assertTrue(cache.put(firstVisible, visibleKeys))
      assertTrue(cache.put(secondVisible, visibleKeys))
      assertNotNull(cache[firstVisible.request.key])
      assertNotNull(cache[secondVisible.request.key])
      assertFalse(firstVisible.bitmap.isRecycled)
      assertFalse(secondVisible.bitmap.isRecycled)
    } finally {
      cache.clear()
    }
  }

  private fun tile(
    x: Int,
    y: Int,
    priority: Int,
  ): PdfTile {
    val request = PdfTileRequest(
      key = PdfTileKey(
        generation = 1L,
        pageSwitchId = 1L,
        pageIndex = 0,
        level = 0,
        x = x,
        y = y,
      ),
      leftPx = x * androidPdfTileSizePx,
      topPx = y * androidPdfTileSizePx,
      widthPx = 8,
      heightPx = 8,
      scale = 1.0,
      priority = priority,
    )
    return PdfTile(
      request = request,
      bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888),
    )
  }
}
