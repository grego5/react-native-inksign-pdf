package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Typeface
import android.net.Uri
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal class NamedFontResource(
  val source: String,
  val bytes: ByteArray,
  val typeface: Typeface,
  val fsType: Int,
  val file: File,
) {
  fun close() { if (file.exists() && !file.delete()) throw java.io.IOException("Unable to retire named font cache") }
}

/** Owner-local, atomic registry. No synchronous text command reads a URI. */
internal class NamedFontRegistry(private val context: Context) {
  private val names = LinkedHashMap<String, NamedFontResource>()
  private val sources = LinkedHashMap<String, NamedFontResource>()
  private val reader = AndroidFallbackFontResolver(context)

  fun resolve(option: Variant_NullType_String?, previous: NamedFontResource? = null): NamedFontResource? =
    when (option) {
      null -> previous
      is Variant_NullType_String.First -> null
      is Variant_NullType_String.Second -> names[option.value] ?: throw PdfSessionException(
        "font_not_loaded", "The font '${option.value}' has not been loaded by this owner",
      )
    }

  fun selection(font: NamedFontResource?): Variant_NullType_String =
    if (font == null) Variant_NullType_String.create(com.margelo.nitro.core.NullType.NULL)
    else Variant_NullType_String.create(names.entries.first { it.value === font }.key)

  suspend fun load(fonts: Array<NamedFontSource>) {
    val requested = LinkedHashMap<String, String>()
    for (font in fonts) {
      if (font.name.isBlank()) throw PdfSessionException("invalid_font", "Font names must not be blank")
      val source = normalize(font.uri)
      val registered = names[font.name]?.source ?: requested[font.name]
      if (registered != null && registered != source) throw PdfSessionException(
        "font_name_conflict", "The font name '${font.name}' already identifies another source",
      )
      requested[font.name] = source
    }
    val candidates = LinkedHashMap<String, NamedFontResource>()
    try {
      for (source in requested.values.toSet()) {
        if (sources.containsKey(source)) continue
        withContext(Dispatchers.IO) {
          val bytes = reader.readLocalFontBytes(source)
          val font = TrueTypeFont(bytes)
          val file = CacheArtifactPolicy.initialize(context).allocateNamedFont()
          try {
            file.writeBytes(bytes)
            val typeface = if (android.os.Build.VERSION.SDK_INT >= 26) Typeface.Builder(file).build()
              ?: throw PdfSessionException("invalid_font", "Android could not load the TrueType face")
            else Typeface.createFromFile(file).also {
              if (it === Typeface.DEFAULT) throw PdfSessionException("invalid_font", "Android could not load the TrueType face")
            }
            candidates[source] = NamedFontResource(source, bytes, typeface, font.fsType, file)
          } catch (error: Throwable) {
            file.delete()
            throw PdfSessionException("invalid_font", "Unable to create the named font", error)
          }
        }
      }
      sources.putAll(candidates)
      for ((name, source) in requested) names[name] = checkNotNull(sources[source])
    } catch (error: Throwable) {
      withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) { candidates.values.forEach { it.close() } }
      throw error
    }
  }

  fun close() {
    names.clear()
    val resources = sources.values.toList()
    sources.clear()
    resources.forEach { it.close() }
  }

  private fun normalize(source: String): String {
    if (source.isBlank()) throw PdfSessionException("invalid_font", "A local font URI is required")
    val uri = Uri.parse(source).normalizeScheme()
    return when (uri.scheme) {
      null -> if (File(source).isAbsolute) File(source).canonicalPath else source
      "file" -> if (uri.pathSegments.firstOrNull() == "android_res") uri.toString() else {
        if (!uri.authority.isNullOrEmpty() && uri.authority != "localhost")
          throw PdfSessionException("invalid_font", "A font file URI must refer to the local device")
        File(checkNotNull(uri.path)).canonicalPath
      }
      "content", "android.resource" -> uri.toString()
      else -> throw PdfSessionException("invalid_font", "Named fonts require a local source")
    }
  }
}

/** Validates static single-face TrueType outlines and provides exact cmap coverage. */
private class TrueTypeFont(bytes: ByteArray) {
  private val data = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
  private data class Table(val offset: Int, val length: Int)
  private val tables = HashMap<String, Table>()
  val fsType: Int
  private val cmap: Int
  private val cmapEnd: Int
  private val format: Int
  private val glyphCount: Int

  private fun invalid(): Nothing = throw PdfSessionException("invalid_font", "Expected a valid static single-face TrueType-outline font")
  private fun u16(offset: Int): Int { if (offset < 0 || offset.toLong() + 2 > data.limit()) invalid(); return data.getShort(offset).toInt() and 0xffff }
  private fun u32(offset: Int): Long { if (offset < 0 || offset.toLong() + 4 > data.limit()) invalid(); return data.getInt(offset).toLong() and 0xffffffffL }
  private fun table(name: String) = tables[name] ?: invalid()
  private fun within(table: Table, offset: Int, length: Long) {
    if (offset < table.offset || length < 0 || offset.toLong() + length > table.offset.toLong() + table.length) invalid()
  }

  init {
    if (bytes.size < 12 || bytes.size > 64 * 1024 * 1024) invalid()
    val signature = u32(0)
    if (signature != 0x00010000L && signature != 0x74727565L && signature != 0x4f54544fL) invalid()
    val count = u16(4)
    if (12L + count * 16L > bytes.size) invalid()
    repeat(count) { index ->
      val entry = 12 + index * 16
      val tag = String(bytes, entry, 4, Charsets.US_ASCII)
      val offset = u32(entry + 8)
      val length = u32(entry + 12)
      if (offset + length > bytes.size || offset > Int.MAX_VALUE || length > Int.MAX_VALUE || tables.containsKey(tag)) invalid()
      tables[tag] = Table(offset.toInt(), length.toInt())
    }
    if (listOf("fvar", "CFF ", "CFF2").any { it in tables }) invalid()
    listOf("head", "hhea", "hmtx", "maxp", "loca", "glyf", "cmap").forEach { table(it) }
    val maxp = table("maxp"); within(maxp, maxp.offset, 6); glyphCount = u16(maxp.offset + 4)
    if (glyphCount == 0) invalid()
    val head = table("head"); within(head, head.offset, 54)
    if (u32(head.offset + 12) != 0x5f0f3cf5L || u16(head.offset + 18) !in 16..16384) invalid()
    val locationFormat = u16(head.offset + 50)
    if (locationFormat != 0 && locationFormat != 1) invalid()
    val hhea = table("hhea"); within(hhea, hhea.offset, 36)
    val metricsCount = u16(hhea.offset + 34)
    if (metricsCount !in 1..glyphCount) invalid()
    val metrics = table("hmtx"); within(metrics, metrics.offset, metricsCount * 4L + (glyphCount - metricsCount) * 2L)
    val locations = table("loca"); val outlines = table("glyf")
    within(locations, locations.offset, (glyphCount + 1L) * if (locationFormat == 0) 2 else 4)
    var previousLocation = 0L
    for (index in 0..glyphCount) {
      val location = if (locationFormat == 0) u16(locations.offset + index * 2) * 2L else u32(locations.offset + index * 4)
      if (location < previousLocation || location > outlines.length) invalid()
      previousLocation = location
    }
    fsType = tables["OS/2"]?.let { within(it, it.offset, 10); u16(it.offset + 8) } ?: 0
    if (fsType and 0x0202 != 0) invalid() // restricted licence or bitmap-only embedding
    val mapping = table("cmap")
    within(mapping, mapping.offset, 4)
    val records = u16(mapping.offset + 2)
    within(mapping, mapping.offset + 4, records * 8L)
    val supported = (0 until records).mapNotNull { index ->
      val entry = mapping.offset + 4 + index * 8
      val platform = u16(entry)
      val encoding = u16(entry + 2)
      if (platform != 0 && !(platform == 3 && (encoding == 1 || encoding == 10))) return@mapNotNull null
      val relative = u32(entry + 4)
      if (relative > Int.MAX_VALUE || relative + 2 > mapping.length) invalid()
      val offset = mapping.offset + relative.toInt()
      val format = u16(offset)
      if (format == 4 || format == 12) offset to format else null
    }
    val selected = supported.firstOrNull { it.second == 12 } ?: supported.firstOrNull() ?: invalid()
    cmap = selected.first; format = selected.second
    val length = if (format == 12) { within(mapping, cmap, 16); u32(cmap + 4) } else { within(mapping, cmap, 16); u16(cmap + 2).toLong() }
    within(mapping, cmap, length); cmapEnd = cmap + length.toInt()
    if (format == 12) {
      val groups = u32(cmap + 12)
      if (16 + groups * 12 > length) invalid()
      var previous = -1L
      repeat(groups.toInt()) { index ->
        val entry = cmap + 16 + index * 12
        val start = u32(entry); val end = u32(entry + 4); val first = u32(entry + 8)
        if (start <= previous || end < start || end > 0x10ffff || first + end - start >= glyphCount) invalid()
        previous = end
      }
    } else {
      val segments = u16(cmap + 6) / 2
      if (segments == 0 || u16(cmap + 6) % 2 != 0 || 16L + segments * 8 > length) invalid()
      var previous = -1
      repeat(segments) { index ->
        val end = u16(cmap + 14 + index * 2)
        val start = u16(cmap + 16 + segments * 2 + index * 2)
        if (end < start || end <= previous || start <= previous) invalid()
        previous = end
      }
      // Validate every indirect mapping at ingress, never during a synchronous edit.
      for (codePoint in 0..0xffff) glyph(codePoint)
    }
  }

  fun glyph(codePoint: Int): Int {
    if (format == 12) {
      var low = 0; var high = u32(cmap + 12).toInt() - 1
      while (low <= high) {
        val mid = (low + high) ushr 1; val entry = cmap + 16 + mid * 12
        val start = u32(entry); val end = u32(entry + 4)
        when { codePoint < start -> high = mid - 1; codePoint > end -> low = mid + 1
          else -> return (u32(entry + 8) + codePoint - start).toInt() }
      }
      return 0
    }
    if (codePoint > 0xffff) return 0
    val segments = u16(cmap + 6) / 2
    var low = 0; var high = segments - 1
    while (low <= high) {
      val mid = (low + high) ushr 1
      if (codePoint > u16(cmap + 14 + mid * 2)) low = mid + 1 else high = mid - 1
    }
    if (low < segments) {
      val index = low
      val start = u16(cmap + 16 + segments * 2 + index * 2)
      if (codePoint < start) return 0
      val delta = u16(cmap + 16 + segments * 4 + index * 2)
      val location = cmap + 16 + segments * 6 + index * 2
      val range = u16(location)
      val result = if (range == 0) (codePoint + delta) and 0xffff else {
        val address = location.toLong() + range + (codePoint - start) * 2
        if (address + 2 > cmapEnd) invalid()
        val glyph = u16(address.toInt())
        if (glyph == 0) 0 else (glyph + delta) and 0xffff
      }
      if (result >= glyphCount) invalid()
      return result
    }
    return 0
  }
}
