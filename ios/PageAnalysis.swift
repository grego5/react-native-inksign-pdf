import CoreGraphics
import Foundation
import PDFKit

struct InkSignPdfKeyTextMatch {
  let bounds: CGRect
  let sourceIndex: Int
  let lineHeight: CGFloat
  let lineCenterY: CGFloat?

  init(bounds: CGRect,
       sourceIndex: Int,
       lineHeight: CGFloat,
       lineCenterY: CGFloat? = nil) {
    self.bounds = bounds
    self.sourceIndex = sourceIndex
    self.lineHeight = lineHeight
    self.lineCenterY = lineCenterY
  }
}

struct InkSignPdfVisualRow {
  let top: CGFloat
  let bottom: CGFloat

  var centerY: CGFloat { (top + bottom) / 2 }
  var height: CGFloat { bottom - top }
}

struct InkSignPdfTextLookup {
  let hasLiteralMatch: Bool
  let matches: [InkSignPdfKeyTextMatch]
}

struct InkSignPdfDisplayedFieldGeometry {
  let matches: [InkSignPdfKeyTextMatch]
  let rules: [InkSignPdfPlacementRule]
}

struct InkSignPdfPageAnalysis {
  let generation: UInt64
  let pageID: UUID
  let pageIndex: Int
  let pageSize: CGSize
  let sourceText: String
  let characterBounds: [CGRect?]
  let characterVisualRows: [Int]
  let visualRows: [InkSignPdfVisualRow]
  let rules: [InkSignPdfPlacementRule]
  let estimatedMemoryBytes: Int

  /// Cached drawing geometry uses the source orientation fitted to `pageSize`.
  /// Undo that fit before applying the current page orientation.
  func displayedFieldGeometry(lookup: InkSignPdfTextLookup,
                              sourceGeometry: PageGeometry,
                              geometry: PageGeometry) -> InkSignPdfDisplayedFieldGeometry {
    func project(_ point: CGPoint) -> CGPoint {
      let sourceDisplay = CGPoint(x: point.x * sourceGeometry.displaySize.width / pageSize.width,
                                   y: point.y * sourceGeometry.displaySize.height / pageSize.height)
      return geometry.rawToDisplay(sourceGeometry.displayToRaw(sourceDisplay))
    }
    let matches = lookup.matches.map { match in
      let points = [CGPoint(x: match.bounds.minX, y: match.bounds.minY),
                    CGPoint(x: match.bounds.maxX, y: match.bounds.minY),
                    CGPoint(x: match.bounds.minX, y: match.bounds.maxY),
                    CGPoint(x: match.bounds.maxX, y: match.bounds.maxY)].map(project)
      let xs = points.map(\.x), ys = points.map(\.y)
      let bounds = CGRect(x: xs.min()!, y: ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
      let center = match.lineCenterY ?? match.bounds.midY
      let rowTop = project(CGPoint(x: match.bounds.midX, y: center - match.lineHeight / 2))
      let rowBottom = project(CGPoint(x: match.bounds.midX, y: center + match.lineHeight / 2))
      return InkSignPdfKeyTextMatch(bounds: bounds, sourceIndex: match.sourceIndex,
                                    lineHeight: abs(rowBottom.y - rowTop.y),
                                    lineCenterY: (rowTop.y + rowBottom.y) / 2)
    }
    let rules = self.rules.compactMap { rule -> InkSignPdfPlacementRule? in
      let start = project(CGPoint(x: rule.minX, y: rule.y))
      let end = project(CGPoint(x: rule.maxX, y: rule.y))
      guard abs(start.y - end.y) <= 0.001 else { return nil }
      return InkSignPdfPlacementRule(minX: min(start.x, end.x), maxX: max(start.x, end.x), y: start.y)
    }
    return InkSignPdfDisplayedFieldGeometry(matches: matches, rules: rules)
  }

  static func build(generation: UInt64,
                    pageID: UUID,
                    pageIndex: Int,
                    page: PDFPage,
                    mediaBox: CGRect) -> InkSignPdfPageAnalysis {
    let sourceText = page.string ?? ""
    let sourceString = sourceText as NSString
    let pageSize = mediaBox.size
    let pageRef = page.pageRef
    let characterBounds: [CGRect?]
    if let pageRef {
      let transform = pageRef.getDrawingTransform(.mediaBox,
                                                  rect: CGRect(origin: .zero, size: pageSize),
                                                  rotate: 0,
                                                  preserveAspectRatio: false)
      characterBounds = (0..<sourceString.length).map { index -> CGRect? in
        let bounds = page.characterBounds(at: index)
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        return Self.canonicalRect(bounds, transform: transform, pageSize: pageSize)
      }
    } else {
      characterBounds = []
    }
    let rowBounds = characterBounds.enumerated().map { index, bounds -> CGRect? in
      Self.isSpace(sourceString.character(at: index)) ? nil : bounds
    }
    let (characterVisualRows, visualRows) = Self.visualRows(for: rowBounds)
    let rules = pageRef.map {
      InkSignPdfPlacementRuleDetector.scan(page: $0, mediaBox: mediaBox)
    } ?? []
    return InkSignPdfPageAnalysis(generation: generation,
                                  pageID: pageID,
                                  pageIndex: pageIndex,
                                  pageSize: pageSize,
                                  sourceText: sourceText,
                                  characterBounds: characterBounds,
                                  characterVisualRows: characterVisualRows,
                                  visualRows: visualRows,
                                  rules: rules,
                                  estimatedMemoryBytes: sourceString.length * MemoryLayout<UInt16>.stride +
                                    characterBounds.count * MemoryLayout<CGRect?>.stride +
                                    characterVisualRows.count * MemoryLayout<Int>.stride +
                                    visualRows.count * MemoryLayout<InkSignPdfVisualRow>.stride +
                                    rules.count * MemoryLayout<InkSignPdfPlacementRule>.stride + 1024)
  }

  func lookup(key: String) -> InkSignPdfTextLookup {
    guard !key.isEmpty else { return InkSignPdfTextLookup(hasLiteralMatch: false, matches: []) }
    let sourceString = sourceText as NSString
    let keyString = key as NSString
    let keyLength = keyString.length
    func asciiFold(_ value: unichar) -> unichar {
      (value >= 0x41 && value <= 0x5A) ? value + 0x20 : value
    }
    func words(_ text: NSString) -> [(range: NSRange, value: [unichar])] {
      var result: [(range: NSRange, value: [unichar])] = []
      var index = 0
      while index < text.length {
        if Self.isSpace(text.character(at: index)) { index += 1; continue }
        let start = index
        var value: [unichar] = []
        while index < text.length && !Self.isSpace(text.character(at: index)) {
          value.append(asciiFold(text.character(at: index))); index += 1
        }
        result.append((NSRange(location: start, length: index - start), value))
      }
      return result
    }
    func wordCounts(_ words: ArraySlice<(range: NSRange, value: [unichar])>) -> [[unichar]: Int] {
      Dictionary(grouping: words.map(\.value), by: { $0 }).mapValues(\.count)
    }
    let keyWords = words(keyString)
    let multiword = keyWords.count > 1
    var occurrences: [NSRange] = []
    if multiword {
      let wanted = wordCounts(keyWords[...])
      let sourceWords = words(sourceString)
      if sourceWords.count >= keyWords.count {
        for index in 0...(sourceWords.count - keyWords.count) {
          guard wordCounts(sourceWords[index..<(index + keyWords.count)]) == wanted else { continue }
          let start = sourceWords[index].range.location
          let end = NSMaxRange(sourceWords[index + keyWords.count - 1].range)
          occurrences.append(NSRange(location: start, length: end - start))
        }
      }
    } else if keyLength <= sourceString.length {
      for location in 0...(sourceString.length - keyLength) {
        let equal = (0..<keyLength).allSatisfy { offset in
          asciiFold(sourceString.character(at: location + offset)) ==
            asciiFold(keyString.character(at: offset))
        }
        if equal { occurrences.append(NSRange(location: location, length: keyLength)) }
      }
    }

    var hasLiteralMatch = false
    var matches: [InkSignPdfKeyTextMatch] = []
    for occurrence in occurrences {
      let location = occurrence.location
      let end = NSMaxRange(occurrence)
      hasLiteralMatch = true
      guard end <= characterBounds.count else { continue }
      let occurrenceBounds = (location..<end).compactMap { index -> CGRect? in
        Self.isSpace(sourceString.character(at: index)) ? nil : characterBounds[index]
      }
      guard let first = occurrenceBounds.first else { continue }
      let union = occurrenceBounds.dropFirst().reduce(first) { $0.union($1) }
      var matchedRow: Int?
      var sameVisualRow = true
      var wordBounds: [CGRect] = []
      var currentWord: CGRect?
      for index in location..<end {
        let character = sourceString.character(at: index)
        if character == 0x0A || character == 0x0D || character == 0x0B ||
            character == 0x0C || character == 0x85 || character == 0x2028 || character == 0x2029 {
          sameVisualRow = false
        }
        if Self.isSpace(character) {
          if let currentWord { wordBounds.append(currentWord) }
          currentWord = nil
          continue
        }
        if let bounds = characterBounds[index] {
          currentWord = currentWord.map { $0.union(bounds) } ?? bounds
        }
        guard characterBounds[index] != nil else { continue }
        let row = characterVisualRows[index]
        guard row >= 0 else {
          sameVisualRow = false
          continue
        }
        if let matchedRow, matchedRow != row {
          sameVisualRow = false
        } else {
          matchedRow = row
        }
      }
      if let currentWord { wordBounds.append(currentWord) }
      let rowGeometry = sameVisualRow ? matchedRow.map { visualRows[$0] } : nil
      let lineHeight = rowGeometry?.height ?? 0
      if multiword {
        guard rowGeometry != nil, wordBounds.count == keyWords.count else { continue }
        wordBounds.sort { $0.minX < $1.minX }
        guard (1..<wordBounds.count).allSatisfy({ index in
          wordBounds[index].minX - wordBounds[index - 1].maxX <= lineHeight
        }) else { continue }
      }
      guard !union.isNull, !union.isEmpty,
            union.minX >= 0, union.minY >= 0,
            union.maxX <= pageSize.width, union.maxY <= pageSize.height else { continue }
      matches.append(InkSignPdfKeyTextMatch(bounds: union,
                                            sourceIndex: location,
                                            lineHeight: lineHeight,
                                            lineCenterY: rowGeometry?.centerY))
    }
    return InkSignPdfTextLookup(hasLiteralMatch: hasLiteralMatch, matches: matches)
  }

  private static func isSpace(_ value: unichar) -> Bool {
    UnicodeScalar(value).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
  }

  private static func canonicalRect(_ rect: CGRect,
                                   transform: CGAffineTransform,
                                   pageSize: CGSize) -> CGRect {
    let corners = [CGPoint(x: rect.minX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.maxY),
                   CGPoint(x: rect.minX, y: rect.maxY)].map { point -> CGPoint in
      let mapped = point.applying(transform)
      return CGPoint(x: mapped.x, y: pageSize.height - mapped.y)
    }
    let xs = corners.map(\.x)
    let ys = corners.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(),
          let minY = ys.min(), let maxY = ys.max() else { return .null }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private static func visualRows(for bounds: [CGRect?]) -> ([Int], [InkSignPdfVisualRow]) {
    let ordered = bounds.enumerated().compactMap { index, rect -> (center: CGFloat, height: CGFloat, index: Int)? in
      guard let rect else { return nil }
      return (rect.midY, rect.height, index)
    }.sorted { $0.center < $1.center }
    var rows: [(center: CGFloat, height: CGFloat, count: Int, top: CGFloat, bottom: CGFloat)] = []
    var result = [Int](repeating: -1, count: bounds.count)
    for item in ordered {
      if rows.isEmpty || abs(item.center - rows[rows.count - 1].center) >
        max(1.5, min(item.height, rows[rows.count - 1].height) * 0.35) {
        let rect = bounds[item.index]!
        rows.append((item.center, item.height, 1, rect.minY, rect.maxY))
      } else {
        let last = rows.count - 1
        let row = rows[last]
        let count = CGFloat(row.count)
        rows[last] = ((row.center * count + item.center) / (count + 1),
                      (row.height * count + item.height) / (count + 1),
                      row.count + 1,
                      min(row.top, bounds[item.index]!.minY),
                      max(row.bottom, bounds[item.index]!.maxY))
      }
      result[item.index] = rows.count - 1
    }
    return (result, rows.map { InkSignPdfVisualRow(top: $0.top, bottom: $0.bottom) })
  }
}
