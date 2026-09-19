package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfPageLruCacheTest {
  @Test
  fun cacheHitsWithoutReloadingAndEvictsLeastRecentlyUsedPage() {
    val cache = PdfPageLruCache<Int, String>(capacity = 2)
    var loads = 0

    assertEquals("page-0", cache.getOrLoad(0) { loads += 1; "page-0" })
    assertEquals("page-1", cache.getOrLoad(1) { loads += 1; "page-1" })
    assertEquals("page-0", cache.getOrLoad(0) { loads += 1; "reloaded-0" })
    assertEquals("page-2", cache.getOrLoad(2) { loads += 1; "page-2" })

    assertEquals(3, loads)
    assertTrue(cache.containsKey(0))
    assertFalse(cache.containsKey(1))
    assertTrue(cache.containsKey(2))
  }

  @Test
  fun clearRemovesAllGenerationLocalPages() {
    val cache = PdfPageLruCache<Int, String>(capacity = 2)
    cache.getOrLoad(0) { "page-0" }
    cache.getOrLoad(1) { "page-1" }

    cache.clear()

    assertEquals(0, cache.size())
    assertFalse(cache.containsKey(0))
    assertFalse(cache.containsKey(1))
  }
}
