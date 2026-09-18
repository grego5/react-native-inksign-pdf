import CoreText
import CoreGraphics
import PDFKit
import UIKit

/// An immutable, media-box-relative text run recovered from PDFKit. The source
/// font is intentionally not retained: compatibility text is shaped with the
/// current system font while preserving the source size, color, and direction.
struct InkSignPdfCompatibilityTextRun: Equatable {
  enum Direction: Equatable {
    case leftToRight
    case rightToLeft
  }

  struct Color: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    static let black = Color(red: 0, green: 0, blue: 0, alpha: 1)

    var cgColor: CGColor {
      UIColor(red: red, green: green, blue: blue, alpha: alpha).cgColor
    }

    static func from(_ value: Any?) -> Color {
      let color: UIColor
      if let uiColor = value as? UIColor {
        color = uiColor
      } else if let cgColor = value as? CGColor {
        color = UIColor(cgColor: cgColor)
      } else {
        return .black
      }
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
        return Color(red: red, green: green, blue: blue, alpha: alpha)
      }
      var white: CGFloat = 0
      if color.getWhite(&white, alpha: &alpha) {
        return Color(red: white, green: white, blue: white, alpha: alpha)
      }
      return .black
    }
  }

  struct FontStyle: Equatable {
    let bold: Bool
    let italic: Bool
  }

  let text: String
  let bounds: CGRect
  let position: CGPoint
  let fontSize: CGFloat
  let color: Color
  let fontStyle: FontStyle
  let direction: Direction

  init(text: String,
       bounds: CGRect,
       fontSize: CGFloat,
       color: Color,
       fontStyle: FontStyle,
       direction: Direction) {
    self.text = text
    self.bounds = bounds
    self.position = CGPoint(x: direction == .rightToLeft ? bounds.maxX : bounds.minX,
                            y: bounds.minY)
    self.fontSize = fontSize
    self.color = color
    self.fontStyle = fontStyle
    self.direction = direction
  }

  func makeCTFont() -> CTFont {
    var font = UIFont.systemFont(ofSize: fontSize,
                                 weight: fontStyle.bold ? .bold : .regular)
    if fontStyle.italic {
      let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
      if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
        font = UIFont(descriptor: descriptor, size: fontSize)
      }
    }
    return CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
  }

  func hasPaintableScalar() -> Bool {
    guard !text.isEmpty, color.alpha > 0 else { return false }
    let font = makeCTFont()
    return text.unicodeScalars.contains { scalar in
      !Self.isTransparentScalar(scalar) && hasGlyph(String(scalar), in: font)
    }
  }

  /// Keeps every scalar in the Core Text line so advances and bidi shaping are
  /// preserved, while universal ASCII/control scalars and unavailable glyphs
  /// are assigned a transparent foreground color.
  func makeAttributedString() -> NSAttributedString {
    let font = makeCTFont()
    let result = NSMutableAttributedString(string: text, attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
    ])
    var utf16Offset = 0
    for scalar in text.unicodeScalars {
      let scalarText = String(scalar)
      let length = scalarText.utf16.count
      let paintable = !Self.isTransparentScalar(scalar) && hasGlyph(scalarText, in: font)
      result.addAttribute(
        NSAttributedString.Key(kCTForegroundColorAttributeName as String),
        value: paintable ? color.cgColor : UIColor.clear.cgColor,
        range: NSRange(location: utf16Offset, length: length))
      utf16Offset += length
    }
    return result
  }

  func makeLine() -> CTLine {
    CTLineCreateWithAttributedString(makeAttributedString())
  }

  func draw(in context: CGContext) {
    let line = makeLine()
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let x = direction == .rightToLeft ? position.x - width : position.x
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: x, y: position.y + ascent)
    CTLineDraw(line, context)
    context.restoreGState()
  }

  static func isTransparentScalar(_ scalar: Unicode.Scalar) -> Bool {
    let codePoint = scalar.value
    return codePoint <= 0x1F ||
      (0x20...0x7E).contains(codePoint) ||
      (0x7F...0x9F).contains(codePoint) ||
      CharacterSet.whitespacesAndNewlines.contains(scalar) ||
      scalar.properties.isWhitespace
  }

  private func hasGlyph(_ text: String, in font: CTFont) -> Bool {
    let utf16Length = text.utf16.count
    guard utf16Length > 0 else { return false }
    let resolvedFont = CTFontCreateForString(
      font,
      text as CFString,
      CFRange(location: 0, length: utf16Length))
    let postScriptName = CTFontCopyPostScriptName(resolvedFont) as String
    return !postScriptName.localizedCaseInsensitiveContains("lastresort")
  }
}

enum InkSignPdfCompatibilityTextExtractor {
  private struct Observation {
    let text: String
    let bounds: CGRect
    let baseline: CGFloat
    let fontSize: CGFloat
    let color: InkSignPdfCompatibilityTextRun.Color
    let fontStyle: InkSignPdfCompatibilityTextRun.FontStyle
    let isNewline: Bool
  }

  static func extract(from page: PDFPage, geometry: PageGeometry)
    -> [InkSignPdfCompatibilityTextRun] {
    guard geometry.isValid, let attributed = page.attributedString,
          !attributed.string.isEmpty else { return [] }

    let string = attributed.string
    var observations: [Observation] = []
    observations.reserveCapacity(attributed.length)
    var utf16Offset = 0
    for scalar in string.unicodeScalars {
      let scalarText = String(scalar)
      let length = scalarText.utf16.count
      let isNewline = scalar.value == 0x0A || scalar.value == 0x0D
      if isNewline {
        observations.append(Observation(
          text: scalarText,
          bounds: .zero,
          baseline: 0,
          fontSize: 0,
          color: .black,
          fontStyle: .init(bold: false, italic: false),
          isNewline: true))
        utf16Offset += length
        continue
      }
      var attributesRange = NSRange(location: 0, length: 0)
      let attributes = attributed.attributes(at: utf16Offset,
                                             effectiveRange: &attributesRange)
      guard let font = attributes[.font] as? UIFont,
            font.pointSize.isFinite, font.pointSize > 0 else {
        observations.append(Observation(text: "", bounds: .zero, baseline: 0,
                                        fontSize: 0, color: .black,
                                        fontStyle: .init(bold: false, italic: false),
                                        isNewline: true))
        utf16Offset += length
        continue
      }
      let rawBounds = page.characterBounds(at: utf16Offset)
      guard let bounds = canonicalBounds(rawBounds, mediaBox: geometry.mediaBox) else {
        observations.append(Observation(text: "", bounds: .zero, baseline: 0,
                                        fontSize: 0, color: .black,
                                        fontStyle: .init(bold: false, italic: false),
                                        isNewline: true))
        utf16Offset += length
        continue
      }
      observations.append(Observation(
        text: scalarText,
        bounds: bounds,
        baseline: geometry.mediaBox.maxY - rawBounds.minY,
        fontSize: font.pointSize,
        color: .from(attributes[.foregroundColor]),
        fontStyle: InkSignPdfCompatibilityTextRun.FontStyle(
          bold: font.fontDescriptor.symbolicTraits.contains(.traitBold),
          italic: font.fontDescriptor.symbolicTraits.contains(.traitItalic)),
        isNewline: false))
      utf16Offset += length
    }

    var runs: [InkSignPdfCompatibilityTextRun] = []
    var current: [Observation] = []
    for observation in observations {
      if observation.isNewline {
        appendRun(current, to: &runs)
        current.removeAll(keepingCapacity: true)
        continue
      }
      if let previous = current.last, !canJoin(previous, observation) {
        appendRun(current, to: &runs)
        current.removeAll(keepingCapacity: true)
      }
      current.append(observation)
    }
    appendRun(current, to: &runs)
    return runs
  }

  private static func canonicalBounds(_ raw: CGRect, mediaBox: CGRect) -> CGRect? {
    guard raw.minX.isFinite, raw.minY.isFinite,
          raw.width.isFinite, raw.height.isFinite,
          raw.width >= 0, raw.height >= 0 else { return nil }
    let result = CGRect(x: raw.minX - mediaBox.minX,
                        y: mediaBox.maxY - raw.maxY,
                        width: raw.width,
                        height: raw.height)
    guard result.minX.isFinite, result.minY.isFinite,
          result.width.isFinite, result.height.isFinite else { return nil }
    return result
  }

  private static func canJoin(_ previous: Observation, _ next: Observation) -> Bool {
    guard previous.fontSize == next.fontSize,
          previous.color == next.color,
          previous.fontStyle == next.fontStyle else { return false }
    let baselineTolerance = max(1, previous.fontSize * 0.25)
    guard abs(previous.baseline - next.baseline) <= baselineTolerance else { return false }
    let horizontalGap: CGFloat
    if previous.bounds.maxX < next.bounds.minX {
      horizontalGap = next.bounds.minX - previous.bounds.maxX
    } else if next.bounds.maxX < previous.bounds.minX {
      horizontalGap = previous.bounds.minX - next.bounds.maxX
    } else {
      horizontalGap = 0
    }
    return horizontalGap <= max(4, previous.fontSize * 2)
  }

  private static func appendRun(
    _ observations: [Observation],
    to runs: inout [InkSignPdfCompatibilityTextRun]
  ) {
    guard let first = observations.first else { return }
    let text = observations.map(\.text).joined()
    let direction = direction(of: text)
    let bounds = observations.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    let run = InkSignPdfCompatibilityTextRun(
      text: text,
      bounds: bounds,
      fontSize: first.fontSize,
      color: first.color,
      fontStyle: first.fontStyle,
      direction: direction)
    if run.hasPaintableScalar() {
      runs.append(run)
    }
  }

  private static func direction(of text: String)
    -> InkSignPdfCompatibilityTextRun.Direction {
    for scalar in text.unicodeScalars {
      if isStrongRTL(scalar) { return .rightToLeft }
      if CharacterSet.letters.contains(scalar) { return .leftToRight }
    }
    return .leftToRight
  }

  private static func isStrongRTL(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    return (0x0590...0x08FF).contains(value) ||
      (0xFB1D...0xFDFF).contains(value) ||
      (0xFE70...0xFEFF).contains(value) ||
      (0x10800...0x10FFF).contains(value)
  }
}

enum InkSignPdfCompatibilityTextRenderer {
  @discardableResult
  static func drawForPreview(
    _ runs: [InkSignPdfCompatibilityTextRun],
    pageSize: CGSize,
    mediaBox: CGRect,
    pdfToPreview: CGAffineTransform,
    in context: CGContext
  ) -> Bool {
    guard runs.isEmpty || (pageSize.width.isFinite && pageSize.height.isFinite &&
                           pageSize.width > 0 && pageSize.height > 0),
          mediaBox.width.isFinite, mediaBox.height.isFinite,
          mediaBox.width > 0, mediaBox.height > 0 else { return false }
    guard !runs.isEmpty else { return true }
    context.saveGState()
    context.concatenate(pdfToPreview.concatenating(
      CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                        tx: mediaBox.minX, ty: mediaBox.maxY)))
    context.clip(to: CGRect(origin: .zero, size: pageSize))
    runs.forEach { $0.draw(in: context) }
    context.restoreGState()
    return true
  }
}

final class InkSignPdfCompatibilityTextView: UIView {
  private(set) var runs: [InkSignPdfCompatibilityTextRun] = []
  private var pageSize = CGSize.zero
  private var pageToOverlayTransform: CGAffineTransform?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func install(runs: [InkSignPdfCompatibilityTextRun],
               pageSize: CGSize,
               pageToOverlayTransform: CGAffineTransform) {
    self.runs = runs
    self.pageSize = pageSize
    self.pageToOverlayTransform = pageToOverlayTransform
    setNeedsDisplay()
  }

  func clear() {
    runs = []
    pageSize = .zero
    pageToOverlayTransform = nil
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard !runs.isEmpty, let transform = pageToOverlayTransform,
          pageSize.width > 0, pageSize.height > 0,
          let context = UIGraphicsGetCurrentContext() else { return }
    context.saveGState()
    context.clip(to: rect)
    context.concatenate(transform)
    context.clip(to: CGRect(origin: .zero, size: pageSize))
    runs.forEach { $0.draw(in: context) }
    context.restoreGState()
  }
}
