package com.margelo.nitro.inksignpdf

internal data class PreparedTextLabel(
  val match: PdfiumTextKeyMatch,
  val fieldName: String,
  val identity: String,
  val tokens: List<List<Int>>,
  val sourceRanges: List<IntRange>,
)

/** Builds complete visual label candidates independently of the later query. */
internal fun preparedTextLabels(analysis: PdfiumPreparedPageAnalysis): List<PreparedTextLabel> {
  data class Word(
    val start: Int,
    val end: Int,
    val token: List<Int>,
    val bounds: PdfiumTextKeyMatch,
    val row: Int,
  )

  val words = ArrayList<Word>()
  var start = -1
  var row = -1
  val token = ArrayList<Int>()
  var left = Double.POSITIVE_INFINITY
  var top = Double.POSITIVE_INFINITY
  var right = Double.NEGATIVE_INFINITY
  var bottom = Double.NEGATIVE_INFINITY
  var lineCenter = 0.0
  var lineHeight = 0.0
  fun finish(end: Int) {
    if (start >= 0 && token.isNotEmpty() && right > left && bottom > top) {
      words += Word(start, end, token.toList(), PdfiumTextKeyMatch(
        left, top, right, bottom, start.toDouble(), lineCenter / token.size, lineHeight,
      ), row)
    }
    start = -1
    row = -1
    token.clear()
    left = Double.POSITIVE_INFINITY
    top = Double.POSITIVE_INFINITY
    right = Double.NEGATIVE_INFINITY
    bottom = Double.NEGATIVE_INFINITY
    lineCenter = 0.0
    lineHeight = 0.0
  }
  analysis.glyphs.forEachIndexed { index, glyph ->
    val bounds = glyph.bounds
    if (isPreparedWhitespace(glyph.codepoint)) {
      finish(index)
      return@forEachIndexed
    }
    if (bounds == null || glyph.visualRow < 0) {
      finish(index)
      return@forEachIndexed
    }
    if (start >= 0 && glyph.visualRow != row) finish(index)
    if (start < 0) {
      start = index
      row = glyph.visualRow
    }
    token += if (glyph.codepoint in 0x41..0x5A) glyph.codepoint + 0x20 else glyph.codepoint
    left = minOf(left, bounds.left)
    top = minOf(top, bounds.top)
    right = maxOf(right, bounds.right)
    bottom = maxOf(bottom, bounds.bottom)
    lineCenter += bounds.lineCenter
    lineHeight = maxOf(lineHeight, bounds.lineHeight)
  }
  finish(analysis.glyphs.size)
  val rows = words.groupBy { it.row }
  return rows.toSortedMap().values.flatMap { rowWords ->
    val ordered = rowWords.sortedWith(compareBy<Word> { it.bounds.left }.thenBy { it.start })
    val groups = ArrayList<MutableList<Word>>()
    for (word in ordered) {
      val group = groups.lastOrNull()
      val previous = group?.lastOrNull()
      val gap = if (previous == null) Double.POSITIVE_INFINITY else word.bounds.left - previous.bounds.right
      val limit = minOf(word.bounds.lineHeight, previous?.bounds?.lineHeight ?: 0.0)
      if (group == null || gap > limit || gap < -limit) groups += mutableListOf(word) else group += word
    }
    groups.mapNotNull { group ->
      if (group.isEmpty()) return@mapNotNull null
      val minSource = group.minOf { it.start }
      val sourceRanges = group.sortedBy { it.start }.map { it.start until it.end }
      val boxes = sourceRanges.flatMap { range -> range.mapNotNull { analysis.glyphs[it].bounds } }
      if (boxes.isEmpty()) return@mapNotNull null
      val labelTop = boxes.minOf { it.top }
      val labelBottom = boxes.maxOf { it.bottom }
      val match = PdfiumTextKeyMatch(
        boxes.minOf { it.left }, labelTop, boxes.maxOf { it.right }, labelBottom,
        minSource.toDouble(), (labelTop + labelBottom) / 2.0, labelBottom - labelTop,
      )
      val spelling = sourceRanges.joinToString(" ") { range ->
        buildString { range.forEach { appendCodePoint(analysis.glyphs[it].codepoint) } }
      }
      val identity = sourceRanges.joinToString(";") { "${it.first}:${it.last + 1}" }
      PreparedTextLabel(match, spelling, identity, group.map { it.token }, sourceRanges)
    }
  }
}

internal fun embeddedTextInCanonicalRegion(
  glyphs: List<PdfiumPreparedGlyph>, region: PageRect, excluded: List<IntRange> = emptyList(),
): String {
  if (region.right <= region.left || region.bottom <= region.top) return ""
  val selected = glyphs.mapIndexedNotNull { index, glyph ->
    val box = glyph.bounds ?: return@mapIndexedNotNull null
    if (excluded.any { index in it } || Character.isWhitespace(glyph.codepoint) ||
      box.left >= region.right || box.right <= region.left ||
      box.top >= region.bottom || box.bottom <= region.top) null else index
  }
  return buildString {
    var previous: Int? = null
    for (index in selected) {
      previous?.let { prior ->
        if ((prior + 1 until index).any { Character.isWhitespace(glyphs[it].codepoint) }) append(' ')
      }
      appendCodePoint(glyphs[index].codepoint)
      previous = index
    }
  }
}

internal fun completeLabelMatches(labels: List<PreparedTextLabel>, query: String): List<PreparedTextLabel> {
  val queryTokens = tokenizeFieldName(query)
  if (queryTokens.isEmpty()) return emptyList()
  val expected = queryTokens.groupingBy { it }.eachCount()
  return labels.filter { label ->
    label.tokens.size == queryTokens.size && label.tokens.groupingBy { it }.eachCount() == expected
  }
}

internal fun ResolveTextOptions.toAnnotationOptions() = TextAnnotationOptions(
  fontSize, color, direction, maxLines, alignment,
  verticalAnchor ?: if (fieldName != null) TextVerticalAnchor.BOTTOM else TextVerticalAnchor.TOP,
)

internal fun PageRect.toPublicBounds() = TextAnnotationBounds(
  left, top, right - left, bottom - top,
)

private fun tokenizeFieldName(value: String): List<List<Int>> = value
  .codePoints()
  .toArray()
  .fold(mutableListOf<MutableList<Int>>()) { result, codepoint ->
    if (isPreparedWhitespace(codepoint)) {
      if (result.lastOrNull()?.isEmpty() == true) result
      else result.apply { add(mutableListOf()) }
    } else {
      if (result.isEmpty()) result.add(mutableListOf())
      val token = result.last()
      token += if (codepoint in 0x41..0x5A) codepoint + 0x20 else codepoint
      result
    }
  }
  .filter { it.isNotEmpty() }
  .map { it.toList() }

private fun isPreparedWhitespace(value: Int): Boolean =
  value == 0x09 || value == 0x0A || value == 0x0B || value == 0x0C || value == 0x0D ||
    value == 0x20 || value == 0x85 || value == 0xA0 || value == 0x1680 ||
    value in 0x2000..0x200A || value == 0x2028 || value == 0x2029 || value == 0x202F ||
    value == 0x205F || value == 0x3000
