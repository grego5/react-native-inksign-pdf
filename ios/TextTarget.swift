import CoreGraphics
import Foundation

struct InkSignPdfTextTargetOptions {
  var font: InkSignPdfNamedFont?
  var fontName: String?
  var fontSize: Double?
  var color: String?
  var direction: TextDirection?
  var maxLines: Int?
  var alignment: TextAlignment?
  var verticalAnchor: TextVerticalAnchor?

  init(_ value: TextAnnotationOptions?) throws {
    font = nil
    if case .second(let name)? = value?.font { fontName = name } else { fontName = nil }
    fontSize = value?.fontSize
    color = value?.color
    direction = value?.direction
    maxLines = try Self.lineLimit(value?.maxLines)
    alignment = value?.alignment
    verticalAnchor = value?.verticalAnchor
  }

  static func lineLimit(_ value: Double?) throws -> Int? {
    guard let value else { return nil }
    guard value >= 0, let limit = Int(exactly: value) else { throw TextError.invalidOptions }
    return limit
  }

  var publicOptions: TextAnnotationOptions {
    TextAnnotationOptions(untracked: nil, font: fontName.map { .second($0) } ?? .first(.null), fontSize: fontSize, color: color, direction: direction,
      maxLines: maxLines.map(Double.init), alignment: alignment, verticalAnchor: verticalAnchor)
  }
}

struct InkSignPdfTextTarget {
  let id: UInt64
  let pageID: UUID
  var sourceIdentity: String?
  var fieldName: String?
  var canonicalBounds: CGRect
  var options: InkSignPdfTextTargetOptions
  var embeddedValue: String
  var canonicalWritingRule: InkSignPdfCanonicalWritingRule? = nil
  var canonicalDetectionBounds: CGRect
  var excludedSourceRanges: [NSRange] = []

  var annotationOptions: TextAnnotationOptions { options.publicOptions }
}
