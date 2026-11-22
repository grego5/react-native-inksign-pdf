package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.sqrt

internal const val pageBaseLongestEdgePx = 2048
internal const val pageBaseMaxPixels = 4L * 1024L * 1024L
internal const val pageBaseCacheBytes = 32L * 1024L * 1024L

internal data class PageRasterMemoryDiagnostics(val baseRasterBytes: Long, val tileBytes: Long)

internal fun pageBaseRequest(key: PdfTileKey, page: PdfPageDimensions): PdfTileRequest {
  val scale = min(pageBaseLongestEdgePx / maxOf(page.width, page.height),
    sqrt(pageBaseMaxPixels.toDouble() / (page.width * page.height)))
  return PdfTileRequest(key = key, leftPx = 0, topPx = 0,
    widthPx = ceil(page.width * scale).toInt().coerceAtMost(pageBaseLongestEdgePx),
    heightPx = ceil(page.height * scale).toInt().coerceAtMost(pageBaseLongestEdgePx),
    scale = scale, priority = androidPdfTileVisiblePriority, pageRotation = page.rotation)
}

/** UI-owned source rasters. Navigation snapshots borrow; this cache alone recycles. */
internal class PageBaseRasterCache(
  private val render: (Long, PdfTileRequest, (Result<PdfTile>) -> Unit) -> Unit,
  private val protectedPages: () -> Set<String>,
  private val onEvicted: (Bitmap) -> Unit,
  private val maxBytes: Long = pageBaseCacheBytes,
  private val renderingAllowed: (String) -> Boolean = { true },
  private val wantedPages: (() -> Set<String>)? = null,
) {
  private data class Key(val generation: Long, val pageId: String,
    val width: Double, val height: Double, val rotation: Int)
  private class Entry(val request: PdfTileRequest) {
    var bitmap: Bitmap? = null
    var rendering = false
    val waiters = ArrayList<(Result<Bitmap>) -> Unit>()
    val bytes: Long get() = bitmap?.allocationByteCount?.toLong()
      ?: if (rendering) request.widthPx.toLong() * request.heightPx * 4L else 0L
  }
  private val main = Handler(Looper.getMainLooper())
  private val entries = LinkedHashMap<Key, Entry>(4, 0.75f, true)

  val allocatedBytes: Long get() = entries.values.sumOf { it.bytes }

  fun get(generation: Long, pageId: String, page: PdfPageDimensions): Bitmap? {
    checkUi()
    return entries[key(generation, pageId, page)]?.bitmap
  }

  fun request(generation: Long, pageId: String, page: PdfPageDimensions,
    request: PdfTileRequest, completion: (Result<PdfTile>) -> Unit) {
    checkUi()
    val identity = key(generation, pageId, page)
    val entry = entries[identity] ?: Entry(request).also { entries[identity] = it }
    val waiter: (Result<Bitmap>) -> Unit = { result -> completion(result.map { PdfTile(request, it) }) }
    val bitmap = entry.bitmap
    if (bitmap != null) waiter(Result.success(bitmap)) else {
      entry.waiters += waiter
      start(identity, entry)
    }
  }

  /** A deferred request starts when pending reservations or presentation pins permit. */
  fun resumeDeferred() {
    checkUi()
    if (entries.values.none { !it.rendering && it.bitmap == null }) return
    val wanted = wantedPages?.invoke()
    entries.entries.map { it.key to it.value }.forEach { (key, entry) ->
      if (entries[key] !== entry) return@forEach
      if (!entry.rendering && entry.bitmap == null && wanted != null && key.pageId !in wanted) {
        entries.remove(key)
        release(entry)
      } else {
        start(key, entry)
      }
    }
  }

  private fun makeRoom(bytes: Long, protected: Set<String>): Boolean {
    while (allocatedBytes + bytes > maxBytes) {
      val candidate = entries.entries.firstOrNull {
        it.key.pageId !in protected && it.value.bitmap != null
      } ?: return false
      entries.remove(candidate.key)
      release(candidate.value)
    }
    return true
  }

  private fun start(identity: Key, entry: Entry) {
    if (entry.rendering || entry.bitmap != null || !renderingAllowed(identity.pageId)) return
    val bytes = entry.request.widthPx.toLong() * entry.request.heightPx * 4L
    if (!makeRoom(bytes, protectedPages() + identity.pageId)) return
    entry.rendering = true
    render(identity.generation, entry.request) { result ->
      val install = Runnable {
        if (entries[identity] !== entry) {
          result.getOrNull()?.bitmap?.recycle()
          return@Runnable
        }
        var bitmap = result.getOrNull()?.bitmap
        if (bitmap != null && !makeRoom(bitmap.allocationByteCount.toLong() - bytes,
            protectedPages() + identity.pageId)) {
          bitmap.recycle()
          bitmap = null
        }
        entry.bitmap = bitmap
        entry.rendering = false
        if (bitmap == null) entries.remove(identity)
        val delivered: Result<Bitmap> = if (bitmap != null) Result.success(bitmap) else
          Result.failure(result.exceptionOrNull() ?: PdfSessionException(
            "operation_cancelled", "Base raster allocation exceeds available cache"))
        val waiters = entry.waiters.toList()
        entry.waiters.clear()
        waiters.forEach { it(delivered) }
        resumeDeferred()
      }
      if (Looper.myLooper() == Looper.getMainLooper()) install.run()
      else if (!main.post(install)) result.getOrNull()?.bitmap?.recycle()
    }
  }

  fun clear() {
    checkUi()
    val removed = entries.values.toList()
    entries.clear()
    removed.forEach(::release)
  }

  private fun release(entry: Entry) {
    entry.bitmap?.let { onEvicted(it); it.recycle() }
    val cancelled = Result.failure<Bitmap>(PdfSessionException("operation_cancelled", "Page raster retired"))
    val waiters = entry.waiters.toList()
    entry.waiters.clear()
    waiters.forEach { it(cancelled) }
  }

  private fun key(generation: Long, pageId: String, page: PdfPageDimensions) =
    Key(generation, pageId, page.width, page.height, page.rotation)

  private fun checkUi() = check(Looper.myLooper() == Looper.getMainLooper())
}
