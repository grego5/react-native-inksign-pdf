import CoreText
import CoreGraphics
import UIKit

/// Renders immutable text annotations without crossing the worker boundary with
/// UIKit presentation state. All coordinates passed to this type are
/// media-box-relative page units with a top-left origin.
enum InkSignPdfTextRenderer {
  static let exportPixelsPerPageUnit: CGFloat = 2
  static let maximumExportPixels = 16_000_000

  static func intrinsicSize(of text: String, fontSize: CGFloat) -> CGSize {
    precondition(fontSize.isFinite && fontSize > 0,
                 "Text annotation font size must be finite and positive")
    let lines = text.components(separatedBy: "\n")
    let lineHeight = max(UIFont.systemFont(ofSize: fontSize).lineHeight, 1)
    let width = lines.reduce(CGFloat.zero) { widest, line in
      max(widest, typographicWidth(of: line, fontSize: fontSize))
    }
    return CGSize(width: max(width, 1), height: lineHeight * CGFloat(lines.count))
  }

  /// Draws text in a top-left-origin canonical context. The caller owns the
  /// page-to-context transform and may use this for previews or raster layers.
  @discardableResult
  static func drawCanonical(
    _ annotations: [InkSignPdfTextAnnotation],
    pageSize: CGSize,
    in context: CGContext,
    color: UIColor? = nil
  ) -> Bool {
    guard isValidPageSize(pageSize), (color?.cgColor.numberOfComponents ?? 1) > 0 else { return false }
    context.saveGState()
    context.clip(to: CGRect(origin: .zero, size: pageSize))
    for annotation in annotations {
      guard annotation.bounds.minX.isFinite,
            annotation.bounds.minY.isFinite,
            annotation.bounds.width.isFinite,
            annotation.bounds.height.isFinite,
            annotation.fontSize.isFinite,
            annotation.fontSize > 0,
            let lines = makeLines(for: annotation.text,
                                   fontSize: annotation.fontSize,
                                   color: color ?? parseColor(annotation.textColor) ?? .black) else {
        context.restoreGState()
        return false
      }
      context.saveGState()
      context.clip(to: annotation.bounds)
      var lineOriginY = annotation.position.y
      let lineHeight = max(UIFont.systemFont(ofSize: annotation.fontSize).lineHeight, 1)
      for line in lines {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line,
                                       &ascent,
                                       &descent,
                                       &leading)
        // Callers establish canonical top-left page space. Core Text glyphs
        // use a bottom-left text coordinate system, so compensate in the text
        // matrix without changing canonical placement or the caller's CTM.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: annotation.position.x,
                                       y: lineOriginY + ascent)
        CTLineDraw(line, context)
        lineOriginY += lineHeight
      }
      context.restoreGState()
    }
    context.restoreGState()
    return true
  }

  /// Draws canonical annotations into a PDF page. Core Text remains the
  /// preferred path because it preserves selectable/extractable PDF text.
  /// A fixed-resolution transparent layer is used only when the capability
  /// gate cannot construct every required shaped line.
  static func drawForPDF(
    _ annotations: [InkSignPdfTextAnnotation],
    pageSize: CGSize,
    mediaBox: CGRect,
    in context: CGContext
  ) throws {
    guard annotations.isEmpty || isValidPageSize(pageSize),
          mediaBox.minX.isFinite,
          mediaBox.minY.isFinite,
          mediaBox.width.isFinite,
          mediaBox.height.isFinite,
          mediaBox.width > 0,
          mediaBox.height > 0 else {
      throw InkSignPdfTextRenderingError.invalidInput
    }
    guard !annotations.isEmpty else { return }

    if canDrawDirectly(annotations, pageSize: pageSize) {
      context.saveGState()
      context.concatenate(canonicalToPDFTransform(for: mediaBox))
      guard drawCanonical(annotations, pageSize: pageSize, in: context) else {
        context.restoreGState()
        throw InkSignPdfTextRenderingError.invalidInput
      }
      context.restoreGState()
      return
    }

    guard let layer = makeTransparentLayer(annotations, pageSize: pageSize) else {
      throw InkSignPdfTextRenderingError.layerTooLarge
    }
    context.saveGState()
    context.concatenate(canonicalToPDFTransform(for: mediaBox))
    context.interpolationQuality = .high
    context.draw(layer, in: CGRect(origin: .zero, size: pageSize))
    context.restoreGState()
  }

  @discardableResult
  static func drawForPreview(
    _ annotations: [InkSignPdfTextAnnotation],
    pageSize: CGSize,
    mediaBox: CGRect,
    pdfToPreview: CGAffineTransform,
    in context: CGContext
  ) -> Bool {
    guard annotations.isEmpty || isValidPageSize(pageSize),
          mediaBox.minX.isFinite,
          mediaBox.minY.isFinite,
          mediaBox.width.isFinite,
          mediaBox.height.isFinite,
          mediaBox.width > 0,
          mediaBox.height > 0 else { return false }
    guard !annotations.isEmpty else { return true }
    context.saveGState()
    context.concatenate(pdfToPreview.concatenating(canonicalToPDFTransform(for: mediaBox)))
    let result = drawCanonical(annotations, pageSize: pageSize, in: context)
    context.restoreGState()
    return result
  }

  static func canonicalToPDFTransform(for mediaBox: CGRect) -> CGAffineTransform {
    CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                      tx: mediaBox.minX, ty: mediaBox.maxY)
  }

  private static func canDrawDirectly(
    _ annotations: [InkSignPdfTextAnnotation],
    pageSize: CGSize
  ) -> Bool {
    guard isValidPageSize(pageSize) else { return false }
    return annotations.allSatisfy { annotation in
      annotation.bounds.minX.isFinite &&
        annotation.bounds.minY.isFinite &&
        annotation.bounds.width.isFinite &&
        annotation.bounds.height.isFinite &&
        annotation.fontSize.isFinite &&
        annotation.fontSize > 0 &&
        makeLines(for: annotation.text, fontSize: annotation.fontSize, color: .black) != nil
    }
  }

  private static func makeTransparentLayer(
    _ annotations: [InkSignPdfTextAnnotation],
    pageSize: CGSize
  ) -> CGImage? {
    let scale = exportPixelsPerPageUnit
    let pixelWidth = Int(ceil(pageSize.width * scale))
    let pixelHeight = Int(ceil(pageSize.height * scale))
    guard pixelWidth > 0,
          pixelHeight > 0,
          pixelWidth <= Int.max / max(pixelHeight, 1),
          pixelWidth * pixelHeight <= maximumExportPixels else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
    return renderer.image { rendererContext in
      guard drawCanonical(annotations,
                          pageSize: pageSize,
                          in: rendererContext.cgContext) else { return }
    }.cgImage
  }

  private static func typographicWidth(of text: String, fontSize: CGFloat) -> CGFloat {
    guard let line = makeLines(for: text, fontSize: fontSize, color: .black)?.first else {
      return 0
    }
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  private static func makeLines(
    for text: String,
    fontSize: CGFloat,
    color: UIColor
  ) -> [CTLine]? {
    guard fontSize.isFinite, fontSize > 0 else { return nil }
    let font = UIFont.systemFont(ofSize: fontSize)
    let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
    ]
    return text.components(separatedBy: "\n").map {
      CTLineCreateWithAttributedString(NSAttributedString(string: $0,
                                                          attributes: attributes))
    }
  }

  private static func isValidPageSize(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
  }
}

enum InkSignPdfTextRenderingError: Error {
  case invalidInput
  case layerTooLarge
}
