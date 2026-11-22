package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PageBaseRasterCacheTest {
  private val instrumentation = InstrumentationRegistry.getInstrumentation()
  private val page = PdfPageDimensions(100.0, 100.0)

  @Test
  fun consumersShareRasterAcrossSwitchIdsAndClearOwnsRetirement() = instrumentation.runOnMainSync {
    val pending = ArrayList<(Result<PdfTile>) -> Unit>()
    val cache = PageBaseRasterCache(render = { _, _, done -> pending += done },
      protectedPages = { setOf("active") }, onEvicted = {})
    val received = ArrayList<Bitmap>()
    val request = request(0)
    cache.request(1L, "active", page, request) { received += it.getOrThrow().bitmap }
    cache.request(1L, "active", page, request.copy(key = request.key.copy(pageSwitchId = 5L))) {
      received += it.getOrThrow().bitmap
    }
    assertEquals(1, pending.size)
    val bitmap = bitmap()
    pending.single()(Result.success(PdfTile(request, bitmap)))
    assertEquals(2, received.size)
    assertSame(bitmap, received[0])
    assertSame(bitmap, received[1])
    cache.request(1L, "active", page, request) { assertSame(bitmap, it.getOrThrow().bitmap) }
    assertEquals(1, pending.size)
    assertEquals(bitmap.allocationByteCount.toLong(), cache.allocatedBytes)
    cache.clear()
    assertTrue(bitmap.isRecycled)
    assertEquals(0L, cache.allocatedBytes)
  }

  @Test
  fun lateCompletionAfterClearIsRecycledWithoutSecondDelivery() = instrumentation.runOnMainSync {
    lateinit var done: (Result<PdfTile>) -> Unit
    var deliveries = 0
    val cache = PageBaseRasterCache(render = { _, _, completion -> done = completion },
      protectedPages = { emptySet() }, onEvicted = {})
    val request = request(0)
    cache.request(1L, "old", page, request) { deliveries++; assertTrue(it.isFailure) }
    cache.clear()
    assertEquals(1, deliveries)
    val bitmap = bitmap()
    done(Result.success(PdfTile(request, bitmap)))
    assertTrue(bitmap.isRecycled)
    assertEquals(1, deliveries)
    assertEquals(0L, cache.allocatedBytes)
  }

  @Test
  fun cacheDefersThirdReservationThenEvictsOnlyUnpresentedPage() = instrumentation.runOnMainSync {
    val pending = LinkedHashMap<Int, (Result<PdfTile>) -> Unit>()
    val evicted = ArrayList<Bitmap>()
    val cache = PageBaseRasterCache(render = { _, request, done -> pending[request.key.pageIndex] = done },
      protectedPages = { setOf("active") }, onEvicted = { evicted += it }, maxBytes = 8192L)
    cache.request(1L, "active", page, request(0)) { it.getOrThrow() }
    cache.request(1L, "neighbor", page, request(1)) { it.getOrThrow() }
    cache.request(1L, "deferred", page, request(2)) { it.getOrThrow() }
    assertEquals(setOf(0, 1), pending.keys)
    val active = bitmap()
    pending.getValue(0)(Result.success(PdfTile(request(0), active)))
    assertFalse(pending.containsKey(2))
    val neighbor = bitmap()
    pending.getValue(1)(Result.success(PdfTile(request(1), neighbor)))
    assertTrue(pending.containsKey(2))
    assertTrue(neighbor.isRecycled)
    assertFalse(active.isRecycled)
    assertEquals(listOf(neighbor), evicted)
    val third = bitmap()
    pending.getValue(2)(Result.success(PdfTile(request(2), third)))
    assertSame(active, cache.get(1L, "active", page))
    assertSame(third, cache.get(1L, "deferred", page))
    assertTrue(cache.allocatedBytes <= 8192L)
    cache.clear()
  }

  private fun request(index: Int) = PdfTileRequest(PdfTileKey(1L, 1L, index, 0, 0, 0),
    0, 0, 32, 32, 0.32, pageRotation = 0)
  private fun bitmap() = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888)
}
