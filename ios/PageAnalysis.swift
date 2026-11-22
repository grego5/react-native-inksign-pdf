import CoreGraphics
import Foundation

struct InkSignPdfKeyTextMatch {
  let bounds: CGRect
  let sourceIndex: Int
  let lineHeight: CGFloat
  let lineCenterY: CGFloat?
  let rowStart: CGPoint
  let rowEnd: CGPoint

  init(bounds: CGRect,
       sourceIndex: Int,
       lineHeight: CGFloat,
       lineCenterY: CGFloat? = nil,
       rowStart: CGPoint? = nil,
       rowEnd: CGPoint? = nil) {
    self.bounds = bounds
    self.sourceIndex = sourceIndex
    self.lineHeight = lineHeight
    self.lineCenterY = lineCenterY
    let centerY = lineCenterY ?? bounds.midY
    self.rowStart = rowStart ?? CGPoint(x: bounds.midX, y: centerY - lineHeight / 2)
    self.rowEnd = rowEnd ?? CGPoint(x: bounds.midX, y: centerY + lineHeight / 2)
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
  let sourceRules: [InkSignPdfCanonicalWritingRule]
}

struct InkSignPdfCanonicalWritingRule {
  let start: CGPoint
  let end: CGPoint
  let sourceIndex: Int
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
  let sourceText: String
  let characterBounds: [CGRect?]
  let characterVisualRows: [Int]
  let rules: [InkSignPdfCanonicalWritingRule]
  let labelCandidates: [InkSignPdfPreparedLabel]

  /// Immutable canonical source geometry is projected for displayed selection.
  func displayedFieldGeometry(lookup: InkSignPdfTextLookup,
                              geometry: PageGeometry) -> InkSignPdfDisplayedFieldGeometry {
    let matches = lookup.matches.map { match in
      let bounds = geometry.canonicalToDisplay(match.bounds)
      let rowStart = geometry.canonicalToDisplay(match.rowStart)
      let rowEnd = geometry.canonicalToDisplay(match.rowEnd)
      return InkSignPdfKeyTextMatch(bounds: bounds, sourceIndex: match.sourceIndex,
        lineHeight: hypot(rowEnd.x - rowStart.x, rowEnd.y - rowStart.y),
        lineCenterY: (rowStart.y + rowEnd.y) / 2, rowStart: rowStart, rowEnd: rowEnd)
    }
    let projected = self.rules.compactMap { rule -> (InkSignPdfCanonicalWritingRule, InkSignPdfPlacementRule)? in
      let start = geometry.canonicalToDisplay(rule.start)
      let end = geometry.canonicalToDisplay(rule.end)
      guard abs(start.y - end.y) <= 0.001 else { return nil }
      return (rule, InkSignPdfPlacementRule(minX: min(start.x, end.x), maxX: max(start.x, end.x), y: start.y))
    }
    return InkSignPdfDisplayedFieldGeometry(matches: matches, rules: projected.map { $0.1 },
                                             sourceRules: projected.map { $0.0 })
  }

  static func build(snapshot: InkSignPdfPdfiumAnalysis) -> InkSignPdfPageAnalysis {
    var units: [UInt16] = []
    var bounds: [CGRect?] = []
    var rows: [Int] = []
    units.reserveCapacity(snapshot.glyphs.count)
    bounds.reserveCapacity(snapshot.glyphs.count)
    rows.reserveCapacity(snapshot.glyphs.count)
    // Every scalar has a source slot, even when it has no drawable geometry.
    // Surrogate pairs repeat its geometry so all downstream NSRanges use UTF-16.
    for glyph in snapshot.glyphs {
      let scalar = UnicodeScalar(glyph.scalar) ?? UnicodeScalar(0xFFFD)!
      for unit in String(scalar).utf16 {
        units.append(unit)
        bounds.append(glyph.hasBounds ? glyph.bounds : nil)
        rows.append(glyph.visualRow)
      }
    }
    let text = String(decoding: units, as: UTF16.self)
    let visualRows = zip(snapshot.rowTops, snapshot.rowBottoms).map {
      InkSignPdfVisualRow(top: CGFloat($0.0.doubleValue), bottom: CGFloat($0.1.doubleValue))
    }
    let rules = snapshot.rules.enumerated().map { index, rule in
      InkSignPdfCanonicalWritingRule(start: rule.start, end: rule.end, sourceIndex: index)
    }
    return InkSignPdfPageAnalysis(sourceText: text, characterBounds: bounds,
      characterVisualRows: rows, rules: rules,
      labelCandidates: prepareLabels(sourceText: text, characterBounds: bounds,
                                      characterVisualRows: rows, visualRows: visualRows))
  }

  func lookup(key: String) -> InkSignPdfTextLookup {
    let wanted = Self.tokens(key)
    guard !wanted.isEmpty else { return InkSignPdfTextLookup(hasLiteralMatch: false, matches: []) }
    let joinedQuery = wanted.flatMap { $0 }
    let exact = labelCandidates.filter { Self.tokens($0.fieldName).flatMap { $0 } == joinedQuery }
    if !exact.isEmpty {
      return InkSignPdfTextLookup(hasLiteralMatch: true, matches: exact.map(\.match))
    }
    let wantedCounts = Self.tokenCounts(wanted)
    let matches = labelCandidates.filter {
      $0.tokens.count == wanted.count && Self.tokenCounts($0.tokens) == wantedCounts
    }.map(\.match)
    return InkSignPdfTextLookup(hasLiteralMatch: !matches.isEmpty, matches: matches)
  }

  func embeddedText(in canonicalBounds: CGRect, excluding ranges: [NSRange] = []) -> String {
    guard !canonicalBounds.isEmpty else { return "" }
    let source = sourceText as NSString
    let excluded = ranges.reduce(into: Set<Int>()) { result, range in
      for index in range.location..<NSMaxRange(range) { result.insert(index) }
    }
    var included = [Bool](repeating: false, count: source.length)
    for index in 0..<min(source.length, characterBounds.count) {
      guard !excluded.contains(index), !Self.isSpace(source.character(at: index)),
            let rect = characterBounds[index],
            rect.minX < canonicalBounds.maxX, rect.maxX > canonicalBounds.minX,
            rect.minY < canonicalBounds.maxY, rect.maxY > canonicalBounds.minY else { continue }
      included[index] = true
    }
    for index in 0..<source.length where !excluded.contains(index) && Self.isSpace(source.character(at: index)) {
      let before = (0..<index).reversed().first { included[$0] }
      let after = ((index + 1)..<source.length).first { included[$0] }
      if let before, let after, characterVisualRows[before] == characterVisualRows[after] { included[index] = true }
    }
    var selectedRanges: [NSRange] = []
    var start: Int?
    for index in 0...source.length {
      let selected = index < source.length && included[index]
      if selected, start == nil { start = index }
      if !selected, let rangeStart = start {
        selectedRanges.append(NSRange(location: rangeStart, length: index - rangeStart))
        start = nil
      }
    }
    return selectedRanges.map { source.substring(with: $0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
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
        appendWord(index)
        continue
      }
      let row = characterVisualRows[index]
      if start != nil && row != currentRow { appendWord(index) }
      if start == nil { start = index; currentRow = row }
      token.append(character >= 0x41 && character <= 0x5A ? character + 0x20 : character)
      union = union.isNull ? bounds : union.union(bounds)
    }
    appendWord(characterCount)

    let wordsByRow = Dictionary(grouping: words, by: \.row)
    var prepared: [InkSignPdfPreparedLabel] = []
    for row in wordsByRow.keys.sorted() {
      guard row >= 0, row < visualRows.count else { continue }
      var ordered: [Word] = wordsByRow[row] ?? []
      ordered.sort { left, right in
        if left.bounds.minX == right.bounds.minX {
          return left.range.location < right.range.location
        }
        return left.bounds.minX < right.bounds.minX
      }
      var groups: [[Word]] = []
      for word in ordered {
        guard let previous = groups.last?.last else { groups.append([word]); continue }
        let gap = word.bounds.minX - previous.bounds.maxX
        let lineHeight = visualRows[row].height
        if gap > lineHeight || gap < -lineHeight { groups.append([word]) }
        else { groups[groups.count - 1].append(word) }
      }
      for group in groups {
        guard !group.isEmpty else { continue }
        let rowGeometry = visualRows[row]
        var ranges: [NSRange] = group.map { $0.range }
        ranges.sort { left, right in left.location < right.location }
        guard let firstRange = ranges.first else { continue }
        let start = firstRange.location
        var end = NSMaxRange(firstRange)
        for range in ranges.dropFirst() { end = max(end, NSMaxRange(range)) }
        guard end > start else { continue }
        var bounds = CGRect.null
        var tokens: [[UInt16]] = []
        for word in group {
          bounds = bounds.isNull ? word.bounds : bounds.union(word.bounds)
          tokens.append(word.token)
        }
        guard !bounds.isNull, !bounds.isEmpty else { continue }
        var spellings: [String] = []
        for range in ranges { spellings.append(source.substring(with: range)) }
        let spelling = spellings.joined(separator: " ")
        prepared.append(InkSignPdfPreparedLabel(sourceRanges: ranges, fieldName: spelling,
          tokens: tokens,
          match: InkSignPdfKeyTextMatch(bounds: bounds, sourceIndex: start,
            lineHeight: rowGeometry.height, lineCenterY: rowGeometry.centerY))
        )
      }
    }
    return prepared
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

}
