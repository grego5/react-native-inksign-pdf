import CoreGraphics
import Foundation

struct InkSignPdfSourceWordID: Hashable {
  let start: Int
  let endExclusive: Int
}

struct InkSignPdfSourceWord {
  let id: InkSignPdfSourceWordID
  let text: String
  let visualRow: Int
  let rectangles: [CGRect]
}

/// Immutable canonical geometry. UTF-16 identities preserve existing analysis indexing.
final class InkSignPdfSourceTextWords {
  let words: [InkSignPdfSourceWord]
  private struct Entry {
    let word: InkSignPdfSourceWord
    let rect: CGRect
  }
  private final class Node {
    let center: CGFloat
    let crossing: [Entry]
    let before: Node?
    let after: Node?

    init(_ entries: [Entry]) {
      let pivot = entries.map { $0.rect.midY }.sorted()[entries.count / 2]
      center = pivot
      crossing = entries.filter { $0.rect.minY <= pivot && $0.rect.maxY >= pivot }
      let low = entries.filter { $0.rect.maxY < pivot }
      let high = entries.filter { $0.rect.minY > pivot }
      before = low.isEmpty ? nil : Node(low)
      after = high.isEmpty ? nil : Node(high)
    }

    func query(top: CGFloat, bottom: CGFloat, visit: (Entry) -> Void) {
      for entry in crossing where entry.rect.minY <= bottom && entry.rect.maxY >= top { visit(entry) }
      if top <= center { before?.query(top: top, bottom: bottom, visit: visit) }
      if bottom >= center { after?.query(top: top, bottom: bottom, visit: visit) }
    }
  }
  private let index: Node?
  private let byID: [InkSignPdfSourceWordID: InkSignPdfSourceWord]

  init(analysis: InkSignPdfPageAnalysis) {
    var result: [InkSignPdfSourceWord] = []
    var start = 0
    var offset = 0
    var row: Int?
    var spelling = ""
    var rectangles: [CGRect] = []
    func flush(_ end: Int) {
      if let row, !rectangles.isEmpty {
        result.append(InkSignPdfSourceWord(id: .init(start: start, endExclusive: end),
          text: spelling, visualRow: row, rectangles: rectangles))
      }
      spelling = ""
      rectangles = []
      row = nil
      start = end
    }
    for scalar in analysis.sourceText.unicodeScalars {
      let length = scalar.value > 0xFFFF ? 2 : 1
      if Self.isWhitespace(scalar.value) {
        flush(offset)
        start = offset + length
      } else {
        // Read only the first UTF-16 slot: surrogate geometry is duplicated in analysis.
        let rect = analysis.characterBounds[offset].flatMap { $0.isEmpty ? nil : $0 }
        let visualRow = analysis.characterVisualRows[offset]
        if rect != nil, let row, row != visualRow { flush(offset) }
        spelling.unicodeScalars.append(scalar)
        if let rect {
          row = visualRow
          rectangles.append(rect)
        }
      }
      offset += length
    }
    flush(offset)
    words = result
    byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
    let entries = result.flatMap { word in word.rectangles.map { Entry(word: word, rect: $0) } }
    index = entries.isEmpty ? nil : Node(entries)
  }

  func word(for id: InkSignPdfSourceWordID) -> InkSignPdfSourceWord { byID[id]! }

  func hit(_ point: CGPoint, tolerance: CGFloat) -> InkSignPdfSourceWord? {
    var best: InkSignPdfSourceWord?
    var distance = CGFloat.infinity
    index?.query(top: point.y - tolerance, bottom: point.y + tolerance) { entry in
      let dx = max(entry.rect.minX - point.x, point.x - entry.rect.maxX, 0)
      let dy = max(entry.rect.minY - point.y, point.y - entry.rect.maxY, 0)
      let squared = dx * dx + dy * dy
      if squared <= tolerance * tolerance && (squared < distance ||
          (squared == distance && entry.word.id.start < (best?.id.start ?? Int.max))) {
        best = entry.word
        distance = squared
      }
    }
    return best
  }

  func crossed(from: CGPoint, to: CGPoint) -> [InkSignPdfSourceWord] {
    var hits: [InkSignPdfSourceWordID: (InkSignPdfSourceWord, CGFloat)] = [:]
    index?.query(top: min(from.y, to.y), bottom: max(from.y, to.y)) { entry in
      if let distance = Self.intersection(from: from, to: to, rect: entry.rect),
         hits[entry.word.id] == nil || distance < hits[entry.word.id]!.1 {
        hits[entry.word.id] = (entry.word, distance)
      }
    }
    return hits.values.sorted {
      if $0.1 != $1.1 { return $0.1 < $1.1 }
      if $0.0.id.start != $1.0.id.start { return $0.0.id.start < $1.0.id.start }
      return $0.0.id.endExclusive < $1.0.id.endExclusive
    }.map { $0.0 }
  }

  private static func intersection(from: CGPoint, to: CGPoint, rect: CGRect) -> CGFloat? {
    var enter: CGFloat = 0
    var exit: CGFloat = 1
    func axis(_ origin: CGFloat, _ delta: CGFloat, _ low: CGFloat, _ high: CGFloat) -> Bool {
      if delta == 0 { return origin >= low && origin <= high }
      let a = (low - origin) / delta
      let b = (high - origin) / delta
      enter = max(enter, min(a, b))
      exit = min(exit, max(a, b))
      return enter <= exit
    }
    return axis(from.x, to.x - from.x, rect.minX, rect.maxX) &&
      axis(from.y, to.y - from.y, rect.minY, rect.maxY) ? enter : nil
  }

  private static func isWhitespace(_ value: UInt32) -> Bool {
    switch value {
    case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
  }
}
