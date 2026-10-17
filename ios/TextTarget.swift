import CoreGraphics
import Foundation

struct InkSignPdfTextTargetOptions {
  var font: InkSignPdfNamedFont?
  var fontSize: Double?
  var color: String?
  var direction: TextDirection?
  var maxLines: Int?
  var alignment: TextAlignment?
  var verticalAnchor: TextVerticalAnchor?

  init(_ value: TextAnnotationOptions?) throws {
    font = nil
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


}

struct InkSignPdfTextTarget {
  let id: UInt64
  let pageID: UUID
  var sourceIdentity: String?
  var fieldName: String?
  private var emptyBounds: CGRect
  private var defaults: InkSignPdfTextTargetOptions
  let state: InkSignPdfTextTargetState
  let mediaBox: CGRect
  var embeddedValue: String
  var canonicalWritingRule: InkSignPdfCanonicalWritingRule?
  var canonicalDetectionBounds: CGRect
  var excludedSourceRanges: [NSRange]

  init(id: UInt64, pageID: UUID, sourceIdentity: String?, fieldName: String?,
       canonicalBounds: CGRect, options: InkSignPdfTextTargetOptions, embeddedValue: String,
       canonicalWritingRule: InkSignPdfCanonicalWritingRule? = nil,
       canonicalDetectionBounds: CGRect, excludedSourceRanges: [NSRange] = [],
       state: InkSignPdfTextTargetState, mediaBox: CGRect) {
    self.id = id; self.pageID = pageID; self.sourceIdentity = sourceIdentity; self.fieldName = fieldName
    emptyBounds = canonicalBounds; defaults = options; self.embeddedValue = embeddedValue
    self.canonicalWritingRule = canonicalWritingRule; self.canonicalDetectionBounds = canonicalDetectionBounds
    self.excludedSourceRanges = excludedSourceRanges; self.state = state; self.mediaBox = mediaBox
  }

  var canonicalBounds: CGRect {
    get { state.placementAnnotation?.canonicalPlacementBounds(mediaBox: mediaBox) ?? emptyBounds }
    set { if state.placementAnnotation == nil { emptyBounds = newValue } }
  }
  var options: InkSignPdfTextTargetOptions {
    get {
      guard let annotation = state.placementAnnotation else { return defaults }
      var result = defaults
      result.font = annotation.font; result.fontSize = Double(annotation.fontSize)
      result.color = annotation.textColor; result.direction = annotation.isRTL ? .rtl : .ltr
      result.maxLines = annotation.maxLines
      switch annotation.alignment { case .start: result.alignment = .start; case .end: result.alignment = .end; case .center: result.alignment = .center }
      result.verticalAnchor = annotation.verticalAnchor == .bottom ? .bottom : .top
      return result
    }
    set { defaults = newValue }
  }
}
