import Foundation
@testable import ReactNativeInkSignPdf

extension HybridAnalyzedPageSpec {
  func resolveInputTarget(options: InputTargetResolutionOptions) throws -> Double {
    if let fieldName = options.fieldName {
      return try resolveInputUnderline(options: ResolveInputUnderlineOptions(
        fieldName: fieldName, bounds: options.bounds, occurrence: options.occurrence,
        font: options.font, fontSize: options.fontSize, color: options.color,
        direction: options.direction, maxLines: options.maxLines,
        alignment: options.alignment, verticalAnchor: options.verticalAnchor))
    }
    return try createInputArea(options: CreateInputAreaOptions(
      bounds: options.bounds!, font: options.font, fontSize: options.fontSize,
      color: options.color, direction: options.direction, maxLines: options.maxLines,
      alignment: options.alignment, verticalAnchor: options.verticalAnchor))
  }
}
