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

  static func paragraph(isRTL: Bool) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    style.alignment = isRTL ? .right : .left
    style.lineBreakMode = .byWordWrapping
    return style
  }

  static func attributes(fontSize: CGFloat,
                         color: UIColor,
                         isRTL: Bool) -> [NSAttributedString.Key: Any] {
    [.font: font(size: fontSize),
     .foregroundColor: color,
     .paragraphStyle: paragraph(isRTL: isRTL)]
  }

  static func apply(to textView: UITextView,
                    fontSize: CGFloat,
                    color: UIColor,
                    isRTL: Bool) {
    let attributes = attributes(fontSize: fontSize, color: color, isRTL: isRTL)
    textView.font = font(size: fontSize)
    textView.textColor = color
    textView.textAlignment = isRTL ? .right : .left
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
      let insets = InkSignPdfTextStyle.presentationInsets
      let contentWidth = max(1, annotation.bounds.width - insets.left - insets.right)
      let lines = makeLineFragments(annotation.text,
                                    fontSize: annotation.fontSize,
                                    color: color,
                                    isRTL: annotation.isRTL,
                                    contentWidth: contentWidth)
      let attributes = InkSignPdfTextStyle.attributes(fontSize: annotation.fontSize,
                                                       color: color,
                                                       isRTL: annotation.isRTL)
      context.saveGState()
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      for fragment in lines {
        let value = fragment.text
        let attributed = NSAttributedString(string: value, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.textPosition = CGPoint(x: annotation.position.x + insets.left + fragment.rect.minX,
                                       y: annotation.position.y + insets.top + fragment.rect.minY + ascent)
        CTLineDraw(line, context)
      }
      context.restoreGState()
    }
    context.restoreGState()
    return true
  }

  static func canonicalToPDFTransform(for mediaBox: CGRect) -> CGAffineTransform {
    CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                      tx: mediaBox.minX, ty: mediaBox.maxY)
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
  }

  private static func makeLineFragments(_ text: String,
                                        fontSize: CGFloat,
                                        color: UIColor,
                                        isRTL: Bool,
                                        contentWidth: CGFloat) -> [LineFragment] {
    let storage = NSTextStorage(attributedString: NSAttributedString(
      string: text,
      attributes: InkSignPdfTextStyle.attributes(fontSize: fontSize,
                                                  color: color,
                                                  isRTL: isRTL)))
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
    manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
      let characterRange = manager.characterRange(forGlyphRange: lineGlyphRange,
                                                    actualGlyphRange: nil)
      let value = (text as NSString).substring(with: characterRange)
      fragments.append(LineFragment(text: value.hasSuffix("\n") ? String(value.dropLast()) : value,
                                    rect: usedRect))
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
