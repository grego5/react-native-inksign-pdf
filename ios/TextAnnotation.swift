import CoreGraphics
import UIKit

enum InkSignPdfTextVerticalAnchor: Equatable {
  case top
  case bottom

  init(_ value: TextVerticalAnchor?) {
    self = value == .bottom ? .bottom : .top
  }

}

enum InkSignPdfTextAlignment: Equatable {
  case start
  case end
  case center

  init(_ value: TextAlignment?) {
    switch value {
    case .some(.start): self = .start
    case .some(.end): self = .end
    case .some(.center): self = .center
    case .none: self = .start
    }
  }
}

enum InkSignPdfTextBoxGeometry {
  /// Accepted page capacity. Fixed axes start at the physical tap; auto axes
  /// retain the requested inner edge and never recenter during measurement.
  static func manualFlow(tap: CGPoint, width: CGFloat?, height: CGFloat?,
                         pageSize: CGSize, isRTL: Bool,
                         alignment: InkSignPdfTextAlignment,
                         verticalAnchor: InkSignPdfTextVerticalAnchor) -> CGRect {
    let rightAnchored = (alignment == .start && isRTL) || (alignment == .end && !isRTL)
    let x = width != nil ? tap.x : alignment == .center
      ? min(max(tap.x, 0.5), pageSize.width - 0.5)
      : min(max(tap.x, rightAnchored ? 1 : 0), pageSize.width - (rightAnchored ? 0 : 1))
    let y = height != nil ? tap.y
      : min(max(tap.y, verticalAnchor == .bottom ? 1 : 0), pageSize.height - (verticalAnchor == .bottom ? 0 : 1))
    let left: CGFloat
    let right: CGFloat
    if let width {
      left = x; right = min(pageSize.width, x + width)
    } else if alignment == .center {
      let radius = max(0.5, min(x, pageSize.width - x))
      left = x - radius; right = x + radius
    } else {
      left = rightAnchored ? 0 : x
      right = rightAnchored ? max(1, x) : pageSize.width
    }
    let top = height != nil || verticalAnchor == .top ? y : 0
    let bottom = height.map { min(pageSize.height, y + $0) }
      ?? (verticalAnchor == .bottom ? max(1, y) : pageSize.height)
    return CGRect(x: left, y: top, width: right - left, height: bottom - top)
  }
  static func outlineBounds(for bounds: CGRect,
                            transform: CGAffineTransform) -> CGRect {
    bounds.applying(transform)
  }

  static func clampedOrigin(for size: CGSize,
                            preferred: CGPoint,
                            pageSize: CGSize) -> CGPoint {
    precondition(pageSize.width.isFinite && pageSize.height.isFinite &&
                   pageSize.width > 0 && pageSize.height > 0,
                 "Text annotation page size must be finite and positive")
    let x = size.width >= pageSize.width
      ? (pageSize.width - size.width) / 2
      : min(max(preferred.x, 0), pageSize.width - size.width)
    let y = size.height >= pageSize.height
      ? (pageSize.height - size.height) / 2
      : min(max(preferred.y, 0), pageSize.height - size.height)
    return CGPoint(x: x, y: y)
  }
}

/// Immutable committed text in the page orientation captured when it was laid out.
/// UIKit editor state, selection, and viewport transforms are intentionally absent.
struct InkSignPdfTextAnnotation: Equatable {
  let id: UInt64
  let text: String
  /// Measured visible text bounds used for selection and auto-sized placement.
  let bounds: CGRect
  let fontSize: CGFloat
  let isRTL: Bool
  /// Canonical opaque RGB color captured with the annotation for export/rendering.
  let textColor: String
  /// Fixed physical flow rectangle in saved layout coordinates. Its edges
  /// stay left-to-right and top-to-bottom regardless of writing direction.
  let flowBounds: CGRect?
  let autoWidth: Bool
  let autoHeight: Bool
  /// Maximum number of complete source-order lines, or zero for no line-count limit.
  let maxLines: Int
  let verticalAnchor: InkSignPdfTextVerticalAnchor
  /// Logical alignment resolved inside `flowBounds` using the saved direction.
  let alignment: InkSignPdfTextAlignment
  /// Orientation whose displayed coordinates define this text layout.
  let layoutRotation: Int
  let font: InkSignPdfNamedFont?

  init(id: UInt64, text: String, bounds: CGRect, fontSize: CGFloat,
       textColor: String = "#000000", isRTL: Bool = false,
       flowBounds: CGRect? = nil, autoWidth: Bool = false, autoHeight: Bool = false,
       maxLines: Int = 0,
       verticalAnchor: InkSignPdfTextVerticalAnchor = .top,
       alignment: InkSignPdfTextAlignment = .start,
       layoutRotation: Int = 0, font: InkSignPdfNamedFont? = nil) {
    precondition(id > 0, "Text annotation ID must be positive")
    precondition(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                 "Committed text annotation must not be blank")
    precondition(bounds.minX.isFinite && bounds.minY.isFinite &&
                   bounds.width.isFinite && bounds.height.isFinite &&
                   bounds.width >= 0 && bounds.height >= 0,
                 "Text annotation bounds must be finite and non-negative")
    precondition(fontSize.isFinite && fontSize > 0,
                 "Text annotation font size must be finite and positive")
    self.id = id
    self.text = text
    self.bounds = bounds
    self.fontSize = fontSize
    self.isRTL = isRTL
    self.textColor = textColor
    self.flowBounds = flowBounds
    self.autoWidth = autoWidth
    self.autoHeight = autoHeight
    self.maxLines = maxLines
    self.verticalAnchor = verticalAnchor
    self.alignment = alignment
    self.layoutRotation = PageGeometry.normalizedRotation(layoutRotation)
    self.font = font
  }

  var position: CGPoint { bounds.origin }
  var intrinsicSize: CGSize { bounds.size }

  func layoutToCanonical(mediaBox: CGRect) -> CGAffineTransform {
    PageGeometry(mediaBox: mediaBox, rotation: 0).layoutToCanonical(rotation: layoutRotation)
  }

  var placementBounds: CGRect {
    let flow = flowBounds ?? bounds
    return CGRect(x: autoWidth ? bounds.minX : flow.minX,
                  y: autoHeight ? bounds.minY : flow.minY,
                  width: autoWidth ? bounds.width : flow.width,
                  height: autoHeight ? bounds.height : flow.height)
  }

  func canonicalPlacementBounds(mediaBox: CGRect) -> CGRect {
    placementBounds.applying(layoutToCanonical(mediaBox: mediaBox))
  }

  func flowForFormatting(isRTL: Bool, alignment: InkSignPdfTextAlignment,
                         verticalAnchor: InkSignPdfTextVerticalAnchor,
                         pageSize: CGSize) -> CGRect? {
    guard let flowBounds else { return nil }
    guard autoWidth && (self.isRTL != isRTL || self.alignment != alignment) ||
            autoHeight && self.verticalAnchor != verticalAnchor else { return flowBounds }
    let right = (alignment == .start && isRTL) || (alignment == .end && !isRTL)
    let x = autoWidth ? (alignment == .center ? bounds.midX : right ? bounds.maxX : bounds.minX) : flowBounds.minX
    let y = autoHeight ? (verticalAnchor == .bottom ? bounds.maxY : bounds.minY) : flowBounds.minY
    return InkSignPdfTextBoxGeometry.manualFlow(tap: CGPoint(x: x, y: y),
      width: autoWidth ? nil : flowBounds.width, height: autoHeight ? nil : flowBounds.height,
      pageSize: pageSize, isRTL: isRTL, alignment: alignment, verticalAnchor: verticalAnchor)
  }

  func replacingText(_ text: String, pageSize: CGSize) -> InkSignPdfTextAnnotation {
    if let flowBounds {
      let bounds = InkSignPdfTextRenderer.visibleBounds(for: text,
                                                        fontSize: fontSize,
                                                        isRTL: isRTL,
                                                        flowBounds: flowBounds,
                                                        maxLines: maxLines,
                                                        verticalAnchor: verticalAnchor,
                                                        alignment: alignment, font: font)
      return InkSignPdfTextAnnotation(id: id, text: text, bounds: bounds,
                                      fontSize: fontSize, textColor: textColor,
                                      isRTL: isRTL, flowBounds: flowBounds, autoWidth: autoWidth, autoHeight: autoHeight,
                                      maxLines: maxLines, verticalAnchor: verticalAnchor,
                                      alignment: alignment, layoutRotation: layoutRotation, font: font)
    }
    let size = Self.intrinsicSize(of: text, fontSize: fontSize,
                                  isRTL: isRTL, maximumWidth: pageSize.width, font: font)
    let origin = InkSignPdfTextBoxGeometry.clampedOrigin(for: size,
                                                        preferred: position,
                                                        pageSize: pageSize)
    return InkSignPdfTextAnnotation(id: id,
                                    text: text,
                                    bounds: CGRect(origin: origin, size: size),
                                    fontSize: fontSize,
                                    textColor: textColor,
                                    isRTL: isRTL,
                                    maxLines: maxLines,
                                    verticalAnchor: verticalAnchor,
                                    alignment: alignment,
                                    layoutRotation: layoutRotation, font: font)
  }

  func moving(to position: CGPoint, pageSize: CGSize) -> InkSignPdfTextAnnotation {
    let sourceFrame = placementBounds
    let requestedFrameOrigin = CGPoint(x: sourceFrame.minX + position.x - bounds.minX,
                                       y: sourceFrame.minY + position.y - bounds.minY)
    let origin = InkSignPdfTextBoxGeometry.clampedOrigin(for: sourceFrame.size,
                                                        preferred: requestedFrameOrigin,
                                                        pageSize: pageSize)
    let offset = CGPoint(x: origin.x - sourceFrame.minX, y: origin.y - sourceFrame.minY)
    let movedFlowBounds = flowBounds.map { flow -> CGRect in
      let right = (alignment == .start && isRTL) || (alignment == .end && !isRTL)
      let x = autoWidth ? (alignment == .center ? flow.midX : right ? flow.maxX : flow.minX) : flow.minX
      let y = autoHeight && verticalAnchor == .bottom ? flow.maxY : flow.minY
      return InkSignPdfTextBoxGeometry.manualFlow(tap: CGPoint(x: x + offset.x, y: y + offset.y),
        width: autoWidth ? nil : flow.width, height: autoHeight ? nil : flow.height,
        pageSize: pageSize, isRTL: isRTL, alignment: alignment, verticalAnchor: verticalAnchor)
    }
    let movedBounds = movedFlowBounds.map {
      InkSignPdfTextRenderer.visibleBounds(for: text, fontSize: fontSize,
                                           isRTL: isRTL, flowBounds: $0,
                                           maxLines: maxLines,
                                           verticalAnchor: verticalAnchor,
                                           alignment: alignment, font: font)
    } ?? bounds.offsetBy(dx: offset.x, dy: offset.y)
    return InkSignPdfTextAnnotation(id: id, text: text,
                                    bounds: movedBounds,
                                    fontSize: fontSize,
                                    textColor: textColor,
                                    isRTL: isRTL,
                                    flowBounds: movedFlowBounds, autoWidth: autoWidth, autoHeight: autoHeight,
                                    maxLines: maxLines,
                                    verticalAnchor: verticalAnchor,
                                    alignment: alignment,
                                    layoutRotation: layoutRotation, font: font)
  }

  func changingFontSize(to fontSize: CGFloat, pageSize: CGSize) -> InkSignPdfTextAnnotation {
    if let flowBounds {
      let bounds = InkSignPdfTextRenderer.visibleBounds(for: text,
                                                        fontSize: fontSize,
                                                        isRTL: isRTL,
                                                        flowBounds: flowBounds,
                                                        maxLines: maxLines,
                                                        verticalAnchor: verticalAnchor,
                                                        alignment: alignment, font: font)
      return InkSignPdfTextAnnotation(id: id, text: text, bounds: bounds,
                                      fontSize: fontSize, textColor: textColor,
                                      isRTL: isRTL, flowBounds: flowBounds, autoWidth: autoWidth, autoHeight: autoHeight,
                                      maxLines: maxLines, verticalAnchor: verticalAnchor,
                                      alignment: alignment, layoutRotation: layoutRotation, font: font)
    }
    let size = Self.intrinsicSize(of: text, fontSize: fontSize,
                                  isRTL: isRTL, maximumWidth: pageSize.width, font: font)
    let origin = InkSignPdfTextBoxGeometry.clampedOrigin(for: size,
                                                        preferred: position,
                                                        pageSize: pageSize)
    return InkSignPdfTextAnnotation(id: id, text: text,
                                    bounds: CGRect(origin: origin, size: size),
                                    fontSize: fontSize,
                                    textColor: textColor,
                                    isRTL: isRTL,
                                    maxLines: maxLines,
                                    verticalAnchor: verticalAnchor,
                                    alignment: alignment,
                                    layoutRotation: layoutRotation, font: font)
  }

  static func intrinsicSize(of text: String,
                            fontSize: CGFloat,
                            isRTL: Bool = false,
                            maximumWidth: CGFloat = .greatestFiniteMagnitude,
                            font: InkSignPdfNamedFont? = nil) -> CGSize {
    InkSignPdfTextRenderer.intrinsicSize(of: text,
                                         fontSize: fontSize,
                                         isRTL: isRTL,
                                         maximumWidth: maximumWidth, font: font)
  }

}
