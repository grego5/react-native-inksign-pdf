import CoreText
import Foundation
import UIKit

/// UTF-16 source offsets and top-left layout positions, before canonical projection.
struct InkSignPdfExportGlyph {
  let glyphID: UInt16
  let sourceOffset: Int
  let unicode: String
  let position: CGPoint
}

struct InkSignPdfExportTextRun {
  let fontIndex: Int
  let fontSize: CGFloat
  let sourceRange: NSRange
  let isRTL: Bool
  let glyphs: [InkSignPdfExportGlyph]
}

struct InkSignPdfExportTextLine {
  let text: String
  let runs: [InkSignPdfExportTextRun]
}

struct InkSignPdfExportTextLayout {
  let lines: [InkSignPdfExportTextLine]
  let transform: CGAffineTransform
  let clip: CGRect?
  let color: String
  let isRTL: Bool
}

/// Export-local resources. No font registration or view lifetime is involved.
final class InkSignPdfCoreTextExportResources {
  private struct FontKey: Hashable {
    let font: CTFont

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.font, rhs.font) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(font)) }
  }

  private(set) var fonts: [Data] = []
  private var fontIndices: [Data: Int] = [:]
  private var resolvedFontIndices: [FontKey: Int] = [:]

  func prepare(_ annotation: InkSignPdfTextAnnotation,
               pageSize: CGSize) throws -> InkSignPdfExportTextLayout {
    guard let color = InkSignPdfTextRenderer.color(from: annotation.textColor) else {
      throw failure("invalid_text_color", "Invalid committed text color")
    }
    let layout = InkSignPdfTextRenderer.positionedLines(annotation, pageSize: pageSize, color: color)
    let lines = try layout.lines.map { positioned -> InkSignPdfExportTextLine in
      let text = positioned.text as NSString
      let runs = CTLineGetGlyphRuns(positioned.line) as! [CTRun]
      let prepared = try runs.map { run -> InkSignPdfExportTextRun in
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let fontValue = attributes[kCTFontAttributeName],
              CFGetTypeID(fontValue as CFTypeRef) == CTFontGetTypeID() else {
          throw failure("export_font_unavailable", "CoreText run has no resolved font")
        }
        let font = fontValue as! CTFont
        let fontIndex = try index(for: font)
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
        let range = CTRunGetStringRange(run)
        guard indices.allSatisfy({ $0 >= range.location && $0 < range.location + range.length }),
              range.location >= 0, range.location + range.length <= text.length else {
          throw failure("export_text_mapping_failed", "Invalid CoreText source cluster")
        }
        // Logical boundaries work for either visual order and retain duplicate clusters.
        let boundaries = Array(Set(indices)).sorted() + [range.location + range.length]
        let ends = Dictionary(uniqueKeysWithValues: zip(boundaries.dropLast(), boundaries.dropFirst()))
        var mapped = Set<Int>()
        let output = glyphs.indices.map { index -> InkSignPdfExportGlyph in
          let start = indices[index]
          let value = mapped.insert(start).inserted
            ? text.substring(with: NSRange(location: start, length: ends[start]! - start)) : ""
          return InkSignPdfExportGlyph(glyphID: glyphs[index], sourceOffset: start,
            unicode: value,
            position: CGPoint(x: positioned.baseline.x + positions[index].x,
                              y: positioned.baseline.y - positions[index].y))
        }
        return InkSignPdfExportTextRun(fontIndex: fontIndex, fontSize: CTFontGetSize(font),
                                      sourceRange: NSRange(location: range.location, length: range.length),
                                      isRTL: CTRunGetStatus(run).contains(.rightToLeft), glyphs: output)
      }
      return InkSignPdfExportTextLine(text: positioned.text, runs: prepared)
    }
    return InkSignPdfExportTextLayout(lines: lines, transform: layout.transform,
                                     clip: layout.clip, color: annotation.textColor, isRTL: annotation.isRTL)
  }

  private func index(for font: CTFont) throws -> Int {
    let key = FontKey(font: font)
    if let cached = resolvedFontIndices[key] { return cached }
    let bytes = try fontData(font)
    let index: Int
    if let existing = fontIndices[bytes] { index = existing }
    else {
      index = fonts.count
      fonts.append(bytes)
      fontIndices[bytes] = index
    }
    resolvedFontIndices[key] = index
    return index
  }

  private func fontData(_ font: CTFont) throws -> Data {
    let name = CTFontCopyPostScriptName(font) as String
    guard CTFontGetMatrix(font).isIdentity else {
      throw failure("export_font_unsupported", "Transformed font instance cannot be embedded exactly: \(name)")
    }
    // Raw tables cannot encode a selected variable instance's interpolated outlines.
    if let variations = CTFontCopyVariation(font), CFDictionaryGetCount(variations) != 0 {
      throw failure("export_font_unsupported", "Variable font instance cannot be embedded exactly: \(name)")
    }
    guard let tags = CTFontCopyAvailableTables(font, []) else {
      throw failure("export_font_unavailable", "No readable font tables: \(name)")
    }
    var tables: [(UInt32, Data)] = []
    // CoreText stores CTFontTableTag integers as raw CFArray pointer values,
    // not CFNumber objects. Bridging this array to [NSNumber] dereferences tags.
    for index in 0..<CFArrayGetCount(tags) {
      let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tags, index)))
      if let data = CTFontCopyTable(font, tag, []) {
        tables.append((tag, data as Data))
      }
    }
    tables.sort { $0.0 < $1.0 }
    guard tables.contains(where: { $0.0 == 0x676c7966 }), // glyf
          tables.contains(where: { $0.0 == 0x6c6f6361 }), // loca
          tables.contains(where: { $0.0 == 0x68656164 }) else { // head
      throw failure("export_font_unsupported", "Exact TrueType outlines unavailable: \(name)")
    }
    var result = Data()
    func append16(_ value: UInt16) { result.append(contentsOf: [UInt8(value >> 8), UInt8(value & 255)]) }
    func append32(_ value: UInt32) {
      result.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255),
                                UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    let count = tables.count
    guard count < 4096 else {
      throw failure("export_font_unsupported", "Invalid font table count: \(name)")
    }
    let power = (0..<16).last(where: { (1 << $0) <= count })!
    append32(0x00010000)
    append16(UInt16(count)); append16(UInt16((1 << power) * 16))
    append16(UInt16(power)); append16(UInt16(count * 16 - (1 << power) * 16))
    var offset = 12 + count * 16
    var headOffset = 0
    for index in tables.indices {
      if tables[index].0 == 0x68656164 {
        guard tables[index].1.count >= 12 else {
          throw failure("export_font_unsupported", "Invalid head table: \(name)")
        }
        tables[index].1.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        headOffset = offset
      }
      append32(tables[index].0); append32(checksum(tables[index].1))
      append32(UInt32(offset)); append32(UInt32(tables[index].1.count))
      offset += (tables[index].1.count + 3) & ~3
    }
    for (_, data) in tables {
      result.append(data)
      while result.count % 4 != 0 { result.append(0) }
    }
    let adjustment = 0xb1b0afba &- checksum(result)
    result.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: [
      UInt8(adjustment >> 24), UInt8((adjustment >> 16) & 255),
      UInt8((adjustment >> 8) & 255), UInt8(adjustment & 255)])
    return result
  }

  private func checksum(_ data: Data) -> UInt32 {
    let bytes = [UInt8](data)
    var total: UInt32 = 0
    for start in stride(from: 0, to: bytes.count, by: 4) {
      var word: UInt32 = 0
      for offset in 0..<4 {
        word = (word << 8) | UInt32(start + offset < bytes.count ? bytes[start + offset] : 0)
      }
      total = total &+ word
    }
    return total
  }

  private func failure(_ code: String, _ message: String) -> NSError {
    NSError(domain: "InkSignPdf.Export", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(code): \(message)", "code": code])
  }
}
