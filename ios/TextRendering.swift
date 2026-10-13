import CoreText
import CoreGraphics
import UIKit

struct TextLayoutMetrics: Equatable {
  let maximumLineWidth: CGFloat
  let lineHeight: CGFloat
  let size: CGSize
}

enum InkSignPdfTextStyle {
  static let presentationInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

  static func font(size: CGFloat) -> UIFont {
    UIFont.systemFont(ofSize: size)
  }

  static func paragraph(isRTL: Bool,
                        alignment: InkSignPdfTextAlignment = .start) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    switch alignment {
    case .start: style.alignment = isRTL ? .right : .left
    case .end: style.alignment = isRTL ? .left : .right
    case .center: style.alignment = .center
    }
    style.lineBreakMode = .byWordWrapping
    return style
  }

  static func attributes(fontSize: CGFloat,
                         color: UIColor,
                         isRTL: Bool,
                         alignment: InkSignPdfTextAlignment = .start) -> [NSAttributedString.Key: Any] {
    [.font: font(size: fontSize),
     .foregroundColor: color,
     .paragraphStyle: paragraph(isRTL: isRTL, alignment: alignment)]
  }

  static func apply(to textView: UITextView,
                    fontSize: CGFloat,
                    color: UIColor,
                    isRTL: Bool,
                    alignment: InkSignPdfTextAlignment = .start) {
    let attributes = attributes(fontSize: fontSize, color: color, isRTL: isRTL, alignment: alignment)
    textView.font = font(size: fontSize)
    textView.textColor = color
    textView.textAlignment = paragraph(isRTL: isRTL, alignment: alignment).alignment
    textView.semanticContentAttribute = isRTL ? .forceRightToLeft : .forceLeftToRight
    if textView.textStorage.length > 0 {
      textView.textStorage.addAttributes(attributes,
                                         range: NSRange(location: 0,
                                                        length: textView.textStorage.length))
    }
    textView.typingAttributes = attributes
  }
}

/// Shapes, measures, and draws committed text using Core Text. Stored text
/// coordinates are media-box-relative page units with a top-left origin.
enum InkSignPdfTextRenderer {
  static func layout(text: String,
                     fontSize: CGFloat,
                     isRTL: Bool = false,
                     contentWidth: CGFloat = .greatestFiniteMagnitude) -> TextLayoutMetrics {
    precondition(fontSize.isFinite && fontSize > 0,
                 "Text annotation font size must be finite and positive")
    let layoutWidth = resolvedContentWidth(contentWidth,
                                           text: text,
                                           fontSize: fontSize)
    let lineHeight = max(InkSignPdfTextStyle.font(size: fontSize).lineHeight, 1)
    let fragments = makeLineFragments(text,
                                      fontSize: fontSize,
                                      color: .black,
                                      isRTL: isRTL,
                                      contentWidth: layoutWidth)
    let widest = fragments.reduce(CGFloat.zero) { max($0, $1.rect.width) }
    let laidOutHeight = fragments.last.map { $0.rect.maxY } ?? lineHeight
    let height = max(laidOutHeight, lineHeight * CGFloat(max(fragments.count, 1)))
    return TextLayoutMetrics(maximumLineWidth: widest,
                             lineHeight: lineHeight,
                             size: CGSize(width: max(widest, 1) +
                                            InkSignPdfTextStyle.presentationInsets.left +
                                            InkSignPdfTextStyle.presentationInsets.right,
                                          height: height +
                                            InkSignPdfTextStyle.presentationInsets.top +
                                            InkSignPdfTextStyle.presentationInsets.bottom))
  }

  static func intrinsicSize(of text: String,
                            fontSize: CGFloat,
                            isRTL: Bool = false,
                            maximumWidth: CGFloat = .greatestFiniteMagnitude) -> CGSize {
    let insets = InkSignPdfTextStyle.presentationInsets
    let contentWidth = max(1, maximumWidth - insets.left - insets.right)
    return layout(text: text,
                  fontSize: fontSize,
                  isRTL: isRTL,
                  contentWidth: contentWidth).size
  }

  /// Draws into canonical top-left page space. The destination context is
  /// responsible for mapping canonical page coordinates to its output space.
  @discardableResult
  static func drawCanonical(
    _ annotations: [InkSignPdfTextAnnotation],
    pageSize: CGSize,
    in context: CGContext,
    color overrideColor: UIColor? = nil
  ) -> Bool {
    guard isValidPageSize(pageSize) else { return false }
    context.saveGState()
    context.clip(to: CGRect(origin: .zero, size: pageSize))
    for annotation in annotations {
      guard isValid(annotation),
            let color = overrideColor ?? Self.color(from: annotation.textColor),
            let components = color.cgColor.components,
            !components.isEmpty else {
        context.restoreGState()
        return false
      }
      let layout = positionedLines(annotation, pageSize: pageSize, color: color)
      context.saveGState()
      context.concatenate(layout.transform)
      if let clip = layout.clip { context.clip(to: clip) }
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      for line in layout.lines {
        context.textPosition = line.baseline
        CTLineDraw(line.line, context)
      }
      context.restoreGState()
    }
    context.restoreGState()
    return true
  }

  struct PositionedLine {
    let text: String
    let line: CTLine
    let baseline: CGPoint
  }

  struct PositionedLayout {
    let lines: [PositionedLine]
    let transform: CGAffineTransform
    let clip: CGRect?
  }

  /// Positions the exact lines used by committed drawing and vector export.
  static func positionedLines(_ annotation: InkSignPdfTextAnnotation,
                              pageSize: CGSize,
                              color: UIColor) -> PositionedLayout {
    let insets = InkSignPdfTextStyle.presentationInsets
    let width = annotation.flowBounds?.width ??
      max(1, annotation.bounds.width - insets.left - insets.right)
    let fragments = makeLineFragments(annotation.text,
                                      fontSize: annotation.fontSize,
                                      color: color,
                                      isRTL: annotation.isRTL,
                                      contentWidth: width,
                                      alignment: annotation.alignment)
    let visible: [LineFragment]
    if let bounds = annotation.flowBounds {
      visible = selectedLineFragments(fragments, flowBounds: bounds,
                                      maxLines: annotation.maxLines,
                                      verticalAnchor: annotation.verticalAnchor)
    } else {
      visible = annotation.maxLines > 0 ? Array(fragments.prefix(annotation.maxLines)) : fragments
    }
    let origin = annotation.flowBounds?.origin ??
      CGPoint(x: annotation.position.x + insets.left, y: annotation.position.y + insets.top)
    let attributes = InkSignPdfTextStyle.attributes(fontSize: annotation.fontSize,
                                                     color: color,
                                                     isRTL: annotation.isRTL,
                                                     alignment: annotation.alignment)
    let lines = visible.map { fragment -> PositionedLine in
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: fragment.text, attributes: attributes))
      var ascent: CGFloat = 0
      _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
      return PositionedLine(text: fragment.text, line: line,
                            baseline: CGPoint(x: origin.x + fragment.rect.minX,
                                              y: origin.y + fragment.rect.minY + ascent))
    }
    return PositionedLayout(lines: lines,
                            transform: annotation.layoutToCanonical(
                              mediaBox: CGRect(origin: .zero, size: pageSize)),
                            clip: annotation.flowBounds)
  }

  static func color(from value: String) -> UIColor? {
    guard value.count == 7, value.first == "#",
          let rgb = UInt32(value.dropFirst(), radix: 16) else { return nil }
    return UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255,
                   green: CGFloat((rgb >> 8) & 0xff) / 255,
                   blue: CGFloat(rgb & 0xff) / 255,
                   alpha: 1)
  }

  private struct LineFragment {
    let text: String
    let rect: CGRect
    let lineBounds: CGRect

    var visibleBounds: CGRect {
      CGRect(x: rect.minX, y: lineBounds.minY,
             width: rect.width, height: lineBounds.height)
    }

    func offsetVertically(by offset: CGFloat) -> LineFragment {
      LineFragment(text: text,
                   rect: rect.offsetBy(dx: 0, dy: offset),
                   lineBounds: lineBounds.offsetBy(dx: 0, dy: offset))
    }
  }

  static func visibleBounds(for text: String,
                            fontSize: CGFloat,
                            isRTL: Bool,
                            flowBounds: CGRect,
                            maxLines: Int = 0,
                            verticalAnchor: InkSignPdfTextVerticalAnchor = .top,
                            alignment: InkSignPdfTextAlignment = .start) -> CGRect {
    let fragments = selectedLineFragments(
      makeLineFragments(text,
                        fontSize: fontSize,
                        color: .black,
                        isRTL: isRTL,
                        contentWidth: flowBounds.width,
                        alignment: alignment),
      flowBounds: flowBounds,
      maxLines: maxLines,
      verticalAnchor: verticalAnchor)
    guard let first = fragments.first else {
      return CGRect(origin: flowBounds.origin, size: .zero)
    }
    let visible = fragments.dropFirst().reduce(first.visibleBounds) {
      $0.union($1.visibleBounds)
    }
    let pageSpace = visible.offsetBy(dx: flowBounds.minX, dy: flowBounds.minY)
    let left = max(pageSpace.minX, flowBounds.minX)
    let top = max(pageSpace.minY, flowBounds.minY)
    return CGRect(x: left,
                  y: top,
                  width: max(0, min(pageSpace.maxX, flowBounds.maxX) - left),
                  height: max(0, min(pageSpace.maxY, flowBounds.maxY) - top))
  }

  static func fits(_ text: String,
                   fontSize: CGFloat,
                   isRTL: Bool,
                   flowBounds: CGRect,
                   maxLines: Int,
                   alignment: InkSignPdfTextAlignment = .start) -> Bool {
    let fragments = makeLineFragments(text,
                                      fontSize: fontSize,
                                      color: .black,
                                      isRTL: isRTL,
                                      contentWidth: flowBounds.width,
                                      alignment: alignment)
    return selectedLineFragments(fragments,
                                 flowBounds: flowBounds,
                                 maxLines: maxLines,
                                 verticalAnchor: .top).count == fragments.count
  }

  static func fitsMaxLines(_ text: String,
                           fontSize: CGFloat,
                           isRTL: Bool,
                           maxLines: Int,
                           maximumWidth: CGFloat,
                           alignment: InkSignPdfTextAlignment) -> Bool {
    guard !text.isEmpty, maxLines > 0 else { return true }
    let insets = InkSignPdfTextStyle.presentationInsets
    let width = max(1, maximumWidth - insets.left - insets.right)
    return makeLineFragments(text,
                             fontSize: fontSize,
                             color: .black,
                             isRTL: isRTL,
                             contentWidth: width,
                             alignment: alignment).count <= maxLines
  }

  private static func selectedLineFragments(
    _ fragments: [LineFragment],
    flowBounds: CGRect,
    maxLines: Int,
    verticalAnchor: InkSignPdfTextVerticalAnchor
  ) -> [LineFragment] {
    var visible = Array(fragments.prefix(while: { $0.lineBounds.maxY <= flowBounds.height }))
    if maxLines > 0 { visible = Array(visible.prefix(maxLines)) }
    guard verticalAnchor == .bottom, let last = visible.last else { return visible }
    let offset = flowBounds.height - last.lineBounds.maxY
    return visible.map { $0.offsetVertically(by: offset) }
  }

  private static func makeLineFragments(_ text: String,
                                        fontSize: CGFloat,
                                        color: UIColor,
                                        isRTL: Bool,
                                        contentWidth: CGFloat,
                                        alignment: InkSignPdfTextAlignment = .start) -> [LineFragment] {
    let storage = NSTextStorage(attributedString: NSAttributedString(
      string: text,
      attributes: InkSignPdfTextStyle.attributes(fontSize: fontSize,
                                                  color: color,
                                                  isRTL: isRTL,
                                                  alignment: alignment)))
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: contentWidth,
                                                 height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.lineBreakMode = .byWordWrapping
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    let glyphRange = NSRange(location: 0, length: manager.numberOfGlyphs)
    var fragments: [LineFragment] = []
    manager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, usedRect, _, lineGlyphRange, _ in
      let characterRange = manager.characterRange(forGlyphRange: lineGlyphRange,
                                                    actualGlyphRange: nil)
      let value = (text as NSString).substring(with: characterRange)
      fragments.append(LineFragment(text: value.hasSuffix("\n") ? String(value.dropLast()) : value,
                                    rect: usedRect,
                                    lineBounds: lineRect))
    }
    return fragments
  }

  private static func resolvedContentWidth(_ requested: CGFloat,
                                           text: String,
                                           fontSize: CGFloat) -> CGFloat {
    guard requested.isFinite, requested < CGFloat.greatestFiniteMagnitude / 2 else {
      return max(fontSize, CGFloat(max(text.utf16.count, 1)) * fontSize * 4)
    }
    return max(1, requested)
  }

  private static func isValid(_ annotation: InkSignPdfTextAnnotation) -> Bool {
    annotation.bounds.minX.isFinite && annotation.bounds.minY.isFinite &&
      annotation.bounds.width.isFinite && annotation.bounds.height.isFinite &&
      annotation.bounds.width >= 0 && annotation.bounds.height >= 0 &&
      annotation.fontSize.isFinite && annotation.fontSize > 0
  }

  private static func isValidPageSize(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
  }

}
