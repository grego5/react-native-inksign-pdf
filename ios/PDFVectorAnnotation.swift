import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// The persisted iOS export representation for committed text and signature
/// geometry. PDFKit writes the overridden drawing into each annotation's
/// appearance stream.
final class InkSignPdfVectorAnnotation: PDFAnnotation {
  private enum Kind: Int {
    case signature = 1
    case text = 2
  }

  private let kind: Kind
  private let mediaBox: CGRect
  private let signaturePath: CGPath?
  private let annotationColor: UIColor
  private let textValue: InkSignPdfTextAnnotation?

  static let printFlag = 1 << 2
  static let readOnlyFlag = 1 << 6
  static let lockedFlag = 1 << 7
  static let lockedContentsFlag = 1 << 9

  static let textFlags = printFlag | lockedFlag | lockedContentsFlag
  static let signatureFlags = textFlags | readOnlyFlag

  init(signatureBounds: CGRect,
       localPath: CGPath,
       color: UIColor,
       mediaBox: CGRect,
       identifier: String) {
    self.kind = .signature
    self.mediaBox = mediaBox
    self.signaturePath = localPath.copy()
    self.annotationColor = color
    self.textValue = nil
    super.init(bounds: signatureBounds, forType: .stamp, withProperties: nil)
    configure(name: "inksign-signature-\(identifier)", flags: Self.signatureFlags)
  }

  init(text: InkSignPdfTextAnnotation,
       mediaBox: CGRect,
       pdfBounds: CGRect,
       color: UIColor,
       identifier: String) {
    self.kind = .text
    self.mediaBox = mediaBox
    self.signaturePath = nil
    self.annotationColor = color
    self.textValue = text
    super.init(bounds: pdfBounds, forType: .freeText, withProperties: nil)
    contents = text.text
    font = UIFont.systemFont(ofSize: text.fontSize)
    fontColor = color
    alignment = text.isRTL ? .right : .left
    configure(name: "inksign-text-\(identifier)", flags: Self.textFlags)
  }

  required init?(coder: NSCoder) {
    guard let kind = Kind(rawValue: coder.decodeInteger(forKey: "inksign.kind")) else {
      return nil
    }
    let mediaBox = coder.decodeCGRect(forKey: "inksign.mediaBox")
    let annotationColor = coder.decodeObject(forKey: "inksign.color") as? UIColor ?? .black
    self.kind = kind
    self.mediaBox = mediaBox
    self.annotationColor = annotationColor
    if kind == .signature {
      guard let path = coder.decodeObject(forKey: "inksign.path") as? UIBezierPath else {
        return nil
      }
      self.signaturePath = path.cgPath.copy()
      self.textValue = nil
    } else {
      guard let id = coder.decodeObject(forKey: "inksign.textID") as? String,
            let text = coder.decodeObject(forKey: "inksign.text") as? String,
            let textColor = coder.decodeObject(forKey: "inksign.textColor") as? String else {
        return nil
      }
      self.signaturePath = nil
      self.textValue = InkSignPdfTextAnnotation(
        id: id,
        text: text,
        bounds: coder.decodeCGRect(forKey: "inksign.textBounds"),
        fontSize: CGFloat(coder.decodeDouble(forKey: "inksign.fontSize")),
        textColor: textColor,
        isRTL: coder.decodeBool(forKey: "inksign.isRTL"))
    }
    super.init(coder: coder)
  }

  override func encode(with coder: NSCoder) {
    super.encode(with: coder)
    coder.encode(kind.rawValue, forKey: "inksign.kind")
    coder.encode(mediaBox, forKey: "inksign.mediaBox")
    coder.encode(annotationColor, forKey: "inksign.color")
    if let signaturePath {
      coder.encode(UIBezierPath(cgPath: signaturePath), forKey: "inksign.path")
    }
    if let textValue {
      coder.encode(textValue.id, forKey: "inksign.textID")
      coder.encode(textValue.text, forKey: "inksign.text")
      coder.encode(textValue.textColor, forKey: "inksign.textColor")
      coder.encode(textValue.bounds, forKey: "inksign.textBounds")
      coder.encode(Double(textValue.fontSize), forKey: "inksign.fontSize")
      coder.encode(textValue.isRTL, forKey: "inksign.isRTL")
    }
  }

  override func copy(with zone: NSZone? = nil) -> Any {
    let copy: InkSignPdfVectorAnnotation
    if let signaturePath {
      copy = InkSignPdfVectorAnnotation(signatureBounds: bounds,
                                        localPath: signaturePath,
                                        color: annotationColor,
                                        mediaBox: mediaBox,
                                        identifier: UUID().uuidString)
    } else if let textValue {
      copy = InkSignPdfVectorAnnotation(text: textValue,
                                        mediaBox: mediaBox,
                                        pdfBounds: bounds,
                                        color: annotationColor,
                                        identifier: UUID().uuidString)
    } else {
      preconditionFailure("Vector annotation has no appearance data")
    }
    copy.contents = contents
    copy.shouldDisplay = shouldDisplay
    copy.shouldPrint = shouldPrint
    if let name = value(forAnnotationKey: .name) {
      precondition(copy.setValue(name, forAnnotationKey: .name))
    }
    if let flags = value(forAnnotationKey: .flags) {
      precondition(copy.setValue(flags, forAnnotationKey: .flags))
    }
    return copy
  }

  override func draw(with box: PDFDisplayBox, in context: CGContext) {
    context.saveGState()
    switch kind {
    case .signature:
      guard let signaturePath else {
        context.restoreGState()
        return
      }
      context.translateBy(x: bounds.minX, y: bounds.minY)
      context.setFillColor(annotationColor.cgColor)
      context.addPath(signaturePath)
      context.fillPath()
    case .text:
      guard let textValue else {
        context.restoreGState()
        return
      }
      context.concatenate(InkSignPdfTextRenderer.canonicalToPDFTransform(for: mediaBox))
      _ = InkSignPdfTextRenderer.drawCanonical([textValue],
                                               pageSize: mediaBox.size,
                                               in: context,
                                               color: annotationColor)
    }
    context.restoreGState()
  }

  static func flags(of annotation: PDFAnnotation) -> Int {
    (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
  }

  private func configure(name: String, flags: Int) {
    shouldDisplay = true
    shouldPrint = true
    let border = PDFBorder()
    border.lineWidth = 0
    self.border = border
    color = .clear
    precondition(setValue(name, forAnnotationKey: .name))
    precondition(setValue(NSNumber(value: flags), forAnnotationKey: .flags))
  }
}
