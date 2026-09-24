import CoreText
import CoreGraphics
import UIKit

struct TextLayoutMetrics: Equatable {
  let lines: [String]
  let maximumLineWidth: CGFloat
  let lineHeight: CGFloat
  let size: CGSize
}

/// Shapes, measures, and draws committed text using Core Text. Stored text
/// coordinates are media-box-relative page units with a top-left origin.
enum InkSignPdfTextRenderer {
  static func layout(text: String, fontSize: CGFloat) -> TextLayoutMetrics {
    precondition(fontSize.isFinite && fontSize > 0,
                 "Text annotation font size must be finite and positive")
    let lines = makeLines(text, fontSize: fontSize, color: .black, rightToLeft: false)
    let lineHeight = max(UIFont.systemFont(ofSize: fontSize).lineHeight, 1)
    let widest = lines.reduce(CGFloat.zero) { current, line in
      max(current, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }
    return TextLayoutMetrics(lines: text.components(separatedBy: "\n"),
                             maximumLineWidth: widest,
                             lineHeight: lineHeight,
                             size: CGSize(width: max(widest, 1),
                                          height: lineHeight * CGFloat(lines.count)))
  }

  static func intrinsicSize(of text: String, fontSize: CGFloat) -> CGSize {
    layout(text: text, fontSize: fontSize).size
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
      let lines = makeLines(annotation.text,
                            fontSize: annotation.fontSize,
                            color: color,
                            rightToLeft: annotation.isRTL)
      let baseFont = makeFont(size: annotation.fontSize)
      context.saveGState()
      context.clip(to: annotation.bounds)
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      var top = annotation.position.y
      for line in lines {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        context.textPosition = CGPoint(x: annotation.position.x, y: top + ascent)
        CTLineDraw(line, context)
        top += max(ascent + descent + leading,
                   CGFloat(CTFontGetSize(baseFont)) * 1.2)
      }
      context.restoreGState()
    }
    context.restoreGState()
    return true
  }

  /// Draws committed text during page previews using the same canonical
  /// coordinates and Core Text shaping as final PDF export.
  @discardableResult
  static func drawForPreview(
    _ annotations: [InkSignPdfTextAnnotation],
    pageSize: CGSize,
    mediaBox: CGRect,
    pdfToPreview: CGAffineTransform,
    in context: CGContext
  ) -> Bool {
    guard annotations.isEmpty || isValidPageSize(pageSize),
          isValidRect(mediaBox) else { return false }
    guard !annotations.isEmpty else { return true }
    context.saveGState()
    context.concatenate(concatenating(pdfToPreview,
                                     canonicalToPDFTransform(for: mediaBox)))
    let result = drawCanonical(annotations, pageSize: pageSize, in: context)
    context.restoreGState()
    return result
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

  private static func makeLines(_ text: String,
                                fontSize: CGFloat,
                                color: UIColor,
                                rightToLeft: Bool) -> [CTLine] {
    let font = makeFont(size: fontSize)
    let foreground = color.cgColor
    let direction: CTWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
    let alignment: CTTextAlignment = rightToLeft ? .right : .left
    let paragraphStyle = withUnsafePointer(to: direction) { directionPointer in
      withUnsafePointer(to: alignment) { alignmentPointer in
        var settings = [
          CTParagraphStyleSetting(spec: .baseWritingDirection,
                                  valueSize: MemoryLayout<CTWritingDirection>.size,
                                  value: UnsafeRawPointer(directionPointer)),
          CTParagraphStyleSetting(spec: .alignment,
                                  valueSize: MemoryLayout<CTTextAlignment>.size,
                                  value: UnsafeRawPointer(alignmentPointer)),
        ]
        return settings.withUnsafeBufferPointer { buffer in
          CTParagraphStyleCreate(buffer.baseAddress!, buffer.count)
        }
      }
    }
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
      NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
    ]
    return text.components(separatedBy: "\n").map { value in
      CTLineCreateWithAttributedString(NSAttributedString(string: value,
                                                          attributes: attributes))
    }
  }

  private static func makeFont(size: CGFloat) -> CTFont {
    let uiFont = UIFont.systemFont(ofSize: size)
    return CTFontCreateWithName(uiFont.fontName as CFString, uiFont.pointSize, nil)
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

  private static func isValidRect(_ rect: CGRect) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite &&
      rect.width.isFinite && rect.height.isFinite &&
      rect.width > 0 && rect.height > 0
  }

  private static func concatenating(_ outer: CGAffineTransform,
                                    _ inner: CGAffineTransform) -> CGAffineTransform {
    CGAffineTransform(
      a: outer.a * inner.a + outer.c * inner.b,
      b: outer.b * inner.a + outer.d * inner.b,
      c: outer.a * inner.c + outer.c * inner.d,
      d: outer.b * inner.c + outer.d * inner.d,
      tx: outer.a * inner.tx + outer.c * inner.ty + outer.tx,
      ty: outer.b * inner.tx + outer.d * inner.ty + outer.ty)
  }
}
