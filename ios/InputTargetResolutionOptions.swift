import Foundation

/// Normalized request shared by underline detection and explicit-area construction.
struct InputTargetResolutionOptions {
  var fieldName: String? = nil
  var bounds: TextAnnotationBounds? = nil
  var occurrence: TextKeyOccurrence? = nil
  var font: Variant_NullType_String? = nil
  var fontSize: Double? = nil
  var color: String? = nil
  var direction: TextDirection? = nil
  var maxLines: Double? = nil
  var alignment: TextAlignment? = nil
  var verticalAnchor: TextVerticalAnchor? = nil

  init(fieldName: String? = nil, bounds: TextAnnotationBounds? = nil,
       occurrence: TextKeyOccurrence? = nil, font: Variant_NullType_String? = nil,
       fontSize: Double? = nil, color: String? = nil, direction: TextDirection? = nil,
       maxLines: Double? = nil, alignment: TextAlignment? = nil,
       verticalAnchor: TextVerticalAnchor? = nil) {
    self.fieldName = fieldName
    self.bounds = bounds
    self.occurrence = occurrence
    self.font = font
    self.fontSize = fontSize
    self.color = color
    self.direction = direction
    self.maxLines = maxLines
    self.alignment = alignment
    self.verticalAnchor = verticalAnchor
  }

  init(_ options: ResolveInputUnderlineOptions) {
    self.init(fieldName: options.fieldName, bounds: options.bounds, occurrence: options.occurrence,
      font: options.font, fontSize: options.fontSize, color: options.color,
      direction: options.direction, maxLines: options.maxLines,
      alignment: options.alignment, verticalAnchor: options.verticalAnchor)
  }

  init(_ options: CreateInputAreaOptions) {
    self.init(bounds: options.bounds, font: options.font, fontSize: options.fontSize,
      color: options.color, direction: options.direction, maxLines: options.maxLines,
      alignment: options.alignment, verticalAnchor: options.verticalAnchor)
  }
}
