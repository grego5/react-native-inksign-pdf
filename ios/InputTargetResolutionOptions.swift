import CoreGraphics
import Foundation

enum InkSignPdfTextDirection {
  case auto
  case ltr
  case rtl

  init(_ value: TextDirection) {
    switch value {
    case .auto: self = .auto
    case .ltr: self = .ltr
    case .rtl: self = .rtl
    }
  }

  var boundaryValue: TextDirection {
    switch self {
    case .auto: return .auto
    case .ltr: return .ltr
    case .rtl: return .rtl
    }
  }
}

enum InkSignPdfFontSelection {
  case system
  case named(String)

  init(_ value: Variant_NullType_String) {
    switch value {
    case .first: self = .system
    case .second(let name): self = .named(name)
    }
  }

  var boundaryValue: Variant_NullType_String {
    switch self {
    case .system: return .first(.null)
    case .named(let name): return .second(name)
    }
  }
}

/// Normalized request shared by underline detection and explicit-area construction.
struct InputTargetResolutionOptions {
  var fieldName: String? = nil
  var bounds: CGRect? = nil
  var occurrence: InkSignPdfFieldOccurrence? = nil
  var font: InkSignPdfFontSelection? = nil
  var fontSize: Double? = nil
  var color: String? = nil
  var direction: InkSignPdfTextDirection? = nil
  var maxLines: Double? = nil
  var alignment: InkSignPdfTextAlignment? = nil
  var verticalAnchor: InkSignPdfTextVerticalAnchor? = nil

  init(fieldName: String? = nil, bounds: CGRect? = nil,
       occurrence: InkSignPdfFieldOccurrence? = nil, font: InkSignPdfFontSelection? = nil,
       fontSize: Double? = nil, color: String? = nil, direction: InkSignPdfTextDirection? = nil,
       maxLines: Double? = nil, alignment: InkSignPdfTextAlignment? = nil,
       verticalAnchor: InkSignPdfTextVerticalAnchor? = nil) {
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
    self.init(fieldName: options.fieldName,
      bounds: options.bounds.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
      occurrence: options.occurrence.map { $0 == .last ? .last : .first },
      font: options.font.map(InkSignPdfFontSelection.init), fontSize: options.fontSize, color: options.color,
      direction: options.direction.map(InkSignPdfTextDirection.init), maxLines: options.maxLines,
      alignment: options.alignment.map { InkSignPdfTextAlignment($0) },
      verticalAnchor: options.verticalAnchor.map { InkSignPdfTextVerticalAnchor($0) })
  }

  init(_ options: CreateInputAreaOptions) {
    self.init(bounds: CGRect(x: options.bounds.x, y: options.bounds.y,
                            width: options.bounds.width, height: options.bounds.height),
      font: options.font.map(InkSignPdfFontSelection.init), fontSize: options.fontSize,
      color: options.color, direction: options.direction.map(InkSignPdfTextDirection.init), maxLines: options.maxLines,
      alignment: options.alignment.map { InkSignPdfTextAlignment($0) },
      verticalAnchor: options.verticalAnchor.map { InkSignPdfTextVerticalAnchor($0) })
  }

  var annotationOptions: TextAnnotationOptions {
    TextAnnotationOptions(untracked: nil, font: font?.boundaryValue, fontSize: fontSize,
      color: color, direction: direction?.boundaryValue, maxLines: maxLines,
      alignment: alignment.map {
        switch $0 { case .start: return .start; case .end: return .end; case .center: return .center }
      },
      verticalAnchor: (verticalAnchor ?? (fieldName == nil ? .top : .bottom)) == .bottom ? .bottom : .top)
  }
}
