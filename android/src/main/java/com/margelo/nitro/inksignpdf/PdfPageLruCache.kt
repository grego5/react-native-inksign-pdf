package com.margelo.nitro.inksignpdf

/** Worker-owned bounded access-order cache used for generation-local page data. */
internal class PdfPageLruCache<K, V>(
  private val capacity: Int,
) {
  init {
    require(capacity > 0)
  }

  private val entries = LinkedHashMap<K, V>(capacity, 0.75f, true)

  fun getOrLoad(key: K, loader: () -> V): V {
    entries[key]?.let { return it }
    val value = loader()
    entries[key] = value
    while (entries.size > capacity) {
      entries.entries.iterator().apply {
        next()
        remove()
      }
    }
    return value
  }

  fun containsKey(key: K): Boolean = entries.containsKey(key)

  fun size(): Int = entries.size

  fun clear() = entries.clear()
}
