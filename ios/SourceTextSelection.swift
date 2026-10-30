import Foundation

/// Main-thread viewer state; the borrowed prepared index retains spelling, geometry and ID lookup.
struct InkSignPdfSourceTextSelection {
  let index: InkSignPdfSourceTextWords
  private(set) var path: [InkSignPdfSourceWordID] = []
  private(set) var isDragging = false
  private var anchor: CGRect = .zero
  private(set) var selectionBox: CGRect = .zero
  var highlightRectangles: [CGRect] { selectedWords.map { $0.rectangles.reduce(CGRect.null) { $0.union($1) } } }
  var selectedWords: [InkSignPdfSourceWord] { path.map(index.word(for:)) }

  init(index: InkSignPdfSourceTextWords) {
    self.index = index
  }

  mutating func begin(_ word: InkSignPdfSourceWord) {
    anchor = word.rectangles.reduce(CGRect.null) { $0.union($1) }
    selectionBox = anchor
    path = [word.id]
    isDragging = true
  }

  mutating func updateBox(to point: CGPoint) {
    guard isDragging else { return }
    selectionBox = CGRect(x: min(anchor.minX, point.x), y: min(anchor.minY, point.y),
      width: max(anchor.maxX, point.x) - min(anchor.minX, point.x),
      height: max(anchor.maxY, point.y) - min(anchor.minY, point.y))
    path = index.words.filter { word in
      word.rectangles.contains { $0.intersects(selectionBox) }
    }.map(\.id)
  }

  mutating func finish() { isDragging = false }
  mutating func clear() { path = []; isDragging = false }

  func copyText() -> String? {
    let words = selectedWords
    guard !words.isEmpty else { return nil }
    var result = ""
    for (offset, word) in words.enumerated() {
      if offset > 0 { result += words[offset - 1].visualRow == word.visualRow ? " " : "\n" }
      result += word.text
    }
    return result
  }
}
