package com.margelo.nitro.inksignpdf

import kotlin.math.max
import kotlin.math.min

internal data class SourceTextWordId(val start: Int, val endExclusive: Int)

internal data class SourceTextWord(
  val id: SourceTextWordId,
  val text: String,
  val visualRow: Int,
  val rectangles: List<PageRect>,
)

/** Immutable canonical geometry, shared by prepared-page consumers. No native handles. */
internal class SourceTextWords(glyphs: List<PdfiumPreparedGlyph>) {
  val words: List<SourceTextWord>
  private data class Entry(val word: SourceTextWord, val rect: PageRect)
  private class Node(entries: List<Entry>) {
    val center = entries.map { (it.rect.top + it.rect.bottom) / 2 }.sorted()[entries.size / 2]
    val crossing = entries.filter { it.rect.top <= center && it.rect.bottom >= center }
    val before = entries.filter { it.rect.bottom < center }.takeIf { it.isNotEmpty() }?.let { Node(it) }
    val after = entries.filter { it.rect.top > center }.takeIf { it.isNotEmpty() }?.let { Node(it) }

    fun query(top: Double, bottom: Double, visit: (Entry) -> Unit) {
      crossing.forEach { if (it.rect.top <= bottom && it.rect.bottom >= top) visit(it) }
      if (top <= center) before?.query(top, bottom, visit)
      if (bottom >= center) after?.query(top, bottom, visit)
    }
  }
  private val index: Node?
  private val byId: Map<SourceTextWordId, SourceTextWord>

  init {
    val result = mutableListOf<SourceTextWord>()
    var start = 0
    var row: Int? = null
    val text = StringBuilder()
    val rectangles = mutableListOf<PageRect>()
    fun flush(end: Int) {
      if (rectangles.isNotEmpty()) result.add(SourceTextWord(
        SourceTextWordId(start, end), text.toString(), checkNotNull(row), rectangles.toList()))
      text.setLength(0)
      rectangles.clear()
      row = null
      start = end
    }
    glyphs.forEachIndexed { offset, glyph ->
      if (sourceTextWhitespace(glyph.codepoint)) {
        flush(offset)
        start = offset + 1
      } else {
        val rect = glyph.bounds?.let { PageRect(it.left, it.top, it.right, it.bottom) }
          ?.takeIf { it.right > it.left && it.bottom > it.top }
        if (rect != null && row != null && row != glyph.visualRow) flush(offset)
        text.appendCodePoint(glyph.codepoint)
        if (rect != null) {
          row = glyph.visualRow
          rectangles.add(rect)
        }
      }
    }
    flush(glyphs.size)
    words = result.toList()
    byId = words.associateBy { it.id }
    val entries = words.flatMap { word -> word.rectangles.map { Entry(word, it) } }
    index = entries.takeIf { it.isNotEmpty() }?.let { Node(it) }
  }

  fun word(id: SourceTextWordId): SourceTextWord = byId.getValue(id)

  fun hit(point: PagePoint, tolerance: Double): SourceTextWord? {
    var best: SourceTextWord? = null
    var distance = Double.POSITIVE_INFINITY
    index?.query(point.y - tolerance, point.y + tolerance) { entry ->
      val rect = entry.rect
      val dx = max(max(rect.left - point.x, point.x - rect.right), 0.0)
      val dy = max(max(rect.top - point.y, point.y - rect.bottom), 0.0)
      val squared = dx * dx + dy * dy
      if (squared <= tolerance * tolerance && (squared < distance ||
          (squared == distance && entry.word.id.start < (best?.id?.start ?: Int.MAX_VALUE)))) {
        best = entry.word
        distance = squared
      }
    }
    return best
  }

  fun crossed(from: PagePoint, to: PagePoint): List<SourceTextWord> {
    val hits = HashMap<SourceTextWordId, Pair<SourceTextWord, Double>>()
    index?.query(min(from.y, to.y), max(from.y, to.y)) { entry ->
      intersection(from, to, entry.rect)?.let { distance ->
        val previous = hits[entry.word.id]
        if (previous == null || distance < previous.second) hits[entry.word.id] = entry.word to distance
      }
    }
    return hits.values.sortedWith(compareBy<Pair<SourceTextWord, Double>> { it.second }
      .thenBy { it.first.id.start }.thenBy { it.first.id.endExclusive }).map { it.first }
  }

  private fun intersection(from: PagePoint, to: PagePoint, rect: PageRect): Double? {
    var enter = 0.0
    var exit = 1.0
    fun axis(origin: Double, delta: Double, low: Double, high: Double): Boolean {
      if (delta == 0.0) return origin >= low && origin <= high
      val a = (low - origin) / delta
      val b = (high - origin) / delta
      enter = max(enter, min(a, b))
      exit = min(exit, max(a, b))
      return enter <= exit
    }
    return if (axis(from.x, to.x - from.x, rect.left, rect.right) &&
      axis(from.y, to.y - from.y, rect.top, rect.bottom)) enter else null
  }
}

private fun sourceTextWhitespace(codepoint: Int): Boolean = when (codepoint) {
  in 0x09..0x0D, 0x20, 0x85, 0xA0, 0x1680, in 0x2000..0x200A,
  0x2028, 0x2029, 0x202F, 0x205F, 0x3000 -> true
  else -> false
}
