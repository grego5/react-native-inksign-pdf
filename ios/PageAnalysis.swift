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
    let (characterVisualRows, visualRows) = Self.visualRows(for: characterBounds)
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
    guard keyLength <= sourceString.length else {
      return InkSignPdfTextLookup(hasLiteralMatch: false, matches: [])
    }
    func asciiFold(_ value: unichar) -> unichar {
      (value >= 0x41 && value <= 0x5A) ? value + 0x20 : value
    }

    var hasLiteralMatch = false
    var matches: [InkSignPdfKeyTextMatch] = []
    for location in 0...(sourceString.length - keyLength) {
      let equal = (0..<keyLength).allSatisfy { offset in
        asciiFold(sourceString.character(at: location + offset)) ==
          asciiFold(keyString.character(at: offset))
      }
      guard equal else { continue }
      hasLiteralMatch = true
      guard location + keyLength <= characterBounds.count else { continue }
      let occurrenceBounds = characterBounds[location..<(location + keyLength)].compactMap { $0 }
      guard let first = occurrenceBounds.first else { continue }
      let union = occurrenceBounds.dropFirst().reduce(first) { $0.union($1) }
      var matchedRow: Int?
      var sameVisualRow = true
      for offset in 0..<keyLength {
        let index = location + offset
        let character = sourceString.character(at: index)
        if character == 0x0A || character == 0x0D || character == 0x0B ||
            character == 0x0C || character == 0x85 || character == 0x2028 || character == 0x2029 {
          sameVisualRow = false
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
      let rowGeometry = sameVisualRow ? matchedRow.map { visualRows[$0] } : nil
      let lineHeight = rowGeometry?.height ?? 0
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
