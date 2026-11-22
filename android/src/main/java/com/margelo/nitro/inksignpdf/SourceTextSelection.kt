package com.margelo.nitro.inksignpdf

/** Main-thread viewer state. The borrowed immutable index owns spelling, geometry and ID lookup. */
internal class SourceTextSelection(val index: SourceTextWords) {
  private val path = mutableListOf<SourceTextWordId>()
  val selectedWords: List<SourceTextWord> get() = path.map(index::word)
  private var anchor = PageRect(0.0, 0.0, 0.0, 0.0)
  var selectionBox = anchor
    private set
  val highlightRectangles: List<PageRect> get() = selectedWords.map { word ->
    PageRect(word.rectangles.minOf { it.left }, word.rectangles.minOf { it.top },
      word.rectangles.maxOf { it.right }, word.rectangles.maxOf { it.bottom })
  }
  var isDragging = false
    private set

  fun begin(word: SourceTextWord) {
    anchor = PageRect(word.rectangles.minOf { it.left }, word.rectangles.minOf { it.top },
      word.rectangles.maxOf { it.right }, word.rectangles.maxOf { it.bottom })
    selectionBox = anchor
    path.clear()
    path.add(word.id)
    isDragging = true
  }

  fun updateBox(point: PagePoint) {
    if (!isDragging) return
    selectionBox = PageRect(minOf(anchor.left, point.x), minOf(anchor.top, point.y),
      maxOf(anchor.right, point.x), maxOf(anchor.bottom, point.y))
    path.clear()
    index.words.filter { word -> word.rectangles.any {
      it.left < selectionBox.right && it.right > selectionBox.left &&
        it.top < selectionBox.bottom && it.bottom > selectionBox.top
    } }.forEach { path.add(it.id) }
  }

  fun finish() { isDragging = false }

  fun clear() {
    path.clear()
    isDragging = false
  }

  fun copyText(): String? {
    if (path.isEmpty()) return null
    val words = selectedWords
    return buildString {
      words.forEachIndexed { offset, word ->
        if (offset > 0) append(if (words[offset - 1].visualRow == word.visualRow) ' ' else '\n')
        append(word.text)
      }
    }
  }
}
