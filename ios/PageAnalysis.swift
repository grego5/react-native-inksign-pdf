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

struct InkSignPdfPreparedLabel {
  let sourceRanges: [NSRange]
  let fieldName: String
  let tokens: [[UInt16]]
  let match: InkSignPdfKeyTextMatch

  var identity: String {
    sourceRanges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
  }
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
  let labelCandidates: [InkSignPdfPreparedLabel]
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
    let labelCandidates = Self.prepareLabels(sourceText: sourceText,
                                             characterBounds: characterBounds,
                                             characterVisualRows: characterVisualRows,
                                             visualRows: visualRows)
    return InkSignPdfPageAnalysis(generation: generation,
                                  pageID: pageID,
                                  pageIndex: pageIndex,
                                  pageSize: pageSize,
                                  sourceText: sourceText,
                                  characterBounds: characterBounds,
                                  characterVisualRows: characterVisualRows,
                                  visualRows: visualRows,
                                  rules: rules,
                                  labelCandidates: labelCandidates,
                                  estimatedMemoryBytes: sourceString.length * MemoryLayout<UInt16>.stride +
                                    characterBounds.count * MemoryLayout<CGRect?>.stride +
                                    characterVisualRows.count * MemoryLayout<Int>.stride +
                                    visualRows.count * MemoryLayout<InkSignPdfVisualRow>.stride +
                                    rules.count * MemoryLayout<InkSignPdfPlacementRule>.stride +
                                    labelCandidates.reduce(0) { total, label in
                                      total + MemoryLayout<InkSignPdfPreparedLabel>.stride +
                                        label.sourceRanges.count * MemoryLayout<NSRange>.stride +
                                        label.tokens.reduce(0) { $0 + $1.count * MemoryLayout<UInt16>.stride }
                                    } + 1024)
  }

  func lookup(key: String) -> InkSignPdfTextLookup {
    let wanted = Self.tokens(key)
    guard !wanted.isEmpty else { return InkSignPdfTextLookup(hasLiteralMatch: false, matches: []) }
    let wantedCounts = Self.tokenCounts(wanted)
    let matches = labelCandidates.filter {
      $0.tokens.count == wanted.count && Self.tokenCounts($0.tokens) == wantedCounts
    }.map(\.match)
    return InkSignPdfTextLookup(hasLiteralMatch: !matches.isEmpty, matches: matches)
  }

  private static func prepareLabels(sourceText: String,
                                    characterBounds: [CGRect?],
                                    characterVisualRows: [Int],
                                    visualRows: [InkSignPdfVisualRow]) -> [InkSignPdfPreparedLabel] {
    struct Word {
      let range: NSRange
      let token: [UInt16]
      let bounds: CGRect
      let row: Int
    }
    let source = sourceText as NSString
    var words: [Word] = []
    var start: Int?
    var currentRow = -1
    var token: [UInt16] = []
    var union: CGRect = .null
    func appendWord(_ end: Int) {
      if let start, !token.isEmpty, !union.isNull, currentRow >= 0 {
        words.append(Word(range: NSRange(location: start, length: end - start),
                          token: token, bounds: union, row: currentRow))
      }
      start = nil
      currentRow = -1
      token.removeAll(keepingCapacity: true)
      union = .null
    }
    let characterCount = min(source.length, min(characterBounds.count, characterVisualRows.count))
    for index in 0..<characterCount {
      let character = source.character(at: index)
      if isSpace(character) { appendWord(index); continue }
      guard let bounds = characterBounds[index], characterVisualRows[index] >= 0 else {
        appendWord(index + 1)
        continue
      }
      let row = characterVisualRows[index]
      if start != nil && row != currentRow { appendWord(index) }
      if start == nil { start = index; currentRow = row }
      token.append(character >= 0x41 && character <= 0x5A ? character + 0x20 : character)
      union = union.isNull ? bounds : union.union(bounds)
    }
    appendWord(source.length)

    let wordsByRow = Dictionary(grouping: words, by: \.row)
    return wordsByRow.keys.sorted().flatMap { row in
      let ordered = (wordsByRow[row] ?? []).sorted {
        $0.bounds.minX == $1.bounds.minX ? $0.range.location < $1.range.location : $0.bounds.minX < $1.bounds.minX
      }
      var groups: [[Word]] = []
      for word in ordered {
        guard let previous = groups.last?.last else { groups.append([word]); continue }
        let gap = word.bounds.minX - previous.bounds.maxX
        let lineHeight = visualRows[row].height
        if gap > lineHeight || gap < -lineHeight { groups.append([word]) }
        else { groups[groups.count - 1].append(word) }
      }
      return groups.compactMap { group in
        guard row >= 0, row < visualRows.count, !group.isEmpty else { return nil }
        let rowGeometry = visualRows[row]
        let ranges = group.map(\.range).sorted { $0.location < $1.location }
        guard let start = ranges.map(\.location).min(),
              let end = ranges.map({ NSMaxRange($0) }).max(), end > start else { return nil }
        let bounds = group.map(\.bounds).reduce(CGRect.null) { $0.isNull ? $1 : $0.union($1) }
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        let spelling = source.substring(with: NSRange(location: start, length: end - start))
        return InkSignPdfPreparedLabel(sourceRanges: ranges, fieldName: spelling,
          tokens: group.map(\.token),
          match: InkSignPdfKeyTextMatch(bounds: bounds, sourceIndex: start,
            lineHeight: rowGeometry.height, lineCenterY: rowGeometry.centerY))
      }
    }
  }

  private static func tokens(_ value: String) -> [[UInt16]] {
    let text = value as NSString
    var result: [[UInt16]] = []
    var token: [UInt16] = []
    for index in 0..<text.length {
      let character = text.character(at: index)
      if isSpace(character) {
        if !token.isEmpty { result.append(token); token.removeAll(keepingCapacity: true) }
      } else {
        token.append(character >= 0x41 && character <= 0x5A ? character + 0x20 : character)
      }
    }
    if !token.isEmpty { result.append(token) }
    return result
  }

  private static func tokenCounts(_ words: [[UInt16]]) -> [[UInt16]: Int] {
    Dictionary(grouping: words, by: { $0 }).mapValues(\.count)
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
