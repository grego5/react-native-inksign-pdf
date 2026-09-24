import CoreGraphics
import Foundation
import PDFKit
import PencilKit

enum InkSignPdfNativeExporterError: Error {
  case unreadableSource
  case invalidPageOrder
  case unsupportedInk
  case writeFailed
  case invalidOutput
}

/// Adds editor content to the source pages as PDF annotations, then verifies
/// the written document and each module-owned appearance stream.
enum InkSignPdfNativeExporter {
  private static let pageBoxes: [PDFDisplayBox] = [
    .mediaBox, .cropBox, .bleedBox, .trimBox, .artBox,
  ]

  static func write(sourceURL: URL,
                    pages: [ExportPageSnapshot],
                    outputURL: URL) throws {
    guard let document = PDFDocument(url: sourceURL),
          document.pageCount == pages.count,
          !pages.isEmpty else {
      throw InkSignPdfNativeExporterError.unreadableSource
    }
    guard pages.enumerated().allSatisfy({ $0.offset == $0.element.pageIndex }) else {
      throw InkSignPdfNativeExporterError.invalidPageOrder
    }

    var moduleAnnotationNames: [Int: [String]] = [:]
    for snapshot in pages {
      guard let page = document.page(at: snapshot.pageIndex),
            sameGeometry(snapshot.geometry, page) else {
        throw InkSignPdfNativeExporterError.invalidOutput
      }
      var names: [String] = []
      names.reserveCapacity(snapshot.textAnnotations.count)
      for text in snapshot.textAnnotations {
        guard let color = InkSignPdfTextRenderer.color(from: text.textColor) else {
          throw InkSignPdfNativeExporterError.invalidOutput
        }
        let name = "\(snapshot.pageID.uuidString)-\(text.id)"
        page.addAnnotation(InkSignPdfVectorAnnotation(
          text: text,
          mediaBox: snapshot.geometry.mediaBox,
          pdfBounds: pdfBounds(for: text.bounds, in: snapshot.geometry.mediaBox),
          color: color,
          identifier: name))
        names.append(name)
      }

      guard let drawing = try? PKDrawing(data: snapshot.drawingData) else {
        throw InkSignPdfNativeExporterError.unsupportedInk
      }
      let strokes: [InkSignPdfFilledStroke]
      do {
        strokes = try InkSignPdfSignatureVectorPath.filledStrokes(in: drawing)
      } catch {
        throw InkSignPdfNativeExporterError.unsupportedInk
      }
      names.reserveCapacity(names.count + strokes.count)
      for (strokeIndex, stroke) in strokes.enumerated() {
        let name = "\(snapshot.pageID.uuidString)-\(strokeIndex)"
        let (bounds, localPath) = try pdfPath(stroke.path,
                                              mediaBox: snapshot.geometry.mediaBox)
        page.addAnnotation(InkSignPdfVectorAnnotation(
          signatureBounds: bounds,
          localPath: localPath,
          color: stroke.color,
          mediaBox: snapshot.geometry.mediaBox,
          identifier: name))
        names.append(name)
      }
      moduleAnnotationNames[snapshot.pageIndex] = names
    }

    guard document.write(to: outputURL),
          let reopened = PDFDocument(url: outputURL),
          reopened.pageCount == document.pageCount else {
      throw InkSignPdfNativeExporterError.writeFailed
    }
    try validate(source: document,
                 output: reopened,
                 pages: pages,
                 moduleAnnotationNames: moduleAnnotationNames)
  }

  private static func validate(source: PDFDocument,
                               output: PDFDocument,
                               pages: [ExportPageSnapshot],
                               moduleAnnotationNames: [Int: [String]]) throws {
    for snapshot in pages {
      guard let sourcePage = source.page(at: snapshot.pageIndex),
            let outputPage = output.page(at: snapshot.pageIndex),
            sameGeometry(snapshot.geometry, outputPage),
            pageBoxesMatch(sourcePage, outputPage) else {
        throw InkSignPdfNativeExporterError.invalidOutput
      }
      for name in moduleAnnotationNames[snapshot.pageIndex] ?? [] {
        guard let annotation = outputPage.annotations.first(where: {
          ($0.value(forAnnotationKey: .name) as? String) == name
        }), annotation.hasAppearanceStream,
        annotation.shouldDisplay, annotation.shouldPrint else {
          throw InkSignPdfNativeExporterError.invalidOutput
        }
        let flags = InkSignPdfVectorAnnotation.flags(of: annotation)
        let requiredFlags = annotation.type?.caseInsensitiveCompare("FreeText") == .orderedSame
          ? InkSignPdfVectorAnnotation.textFlags
          : InkSignPdfVectorAnnotation.signatureFlags
        guard flags & requiredFlags == requiredFlags else {
          throw InkSignPdfNativeExporterError.invalidOutput
        }
        if annotation.type?.caseInsensitiveCompare("FreeText") == .orderedSame {
          guard annotation.type?.caseInsensitiveCompare("FreeText") == .orderedSame,
                pages[snapshot.pageIndex].textAnnotations.contains(where: {
                  name == "\(snapshot.pageID.uuidString)-\($0.id)" &&
                    annotation.contents == $0.text
                }) else {
            throw InkSignPdfNativeExporterError.invalidOutput
          }
        } else {
          guard annotation.type?.caseInsensitiveCompare("Stamp") == .orderedSame else {
            throw InkSignPdfNativeExporterError.invalidOutput
          }
        }
      }
    }
  }

  private static func pdfPath(_ canonicalPath: CGPath,
                              mediaBox: CGRect) throws -> (CGRect, CGPath) {
    var toPDF = InkSignPdfTextRenderer.canonicalToPDFTransform(for: mediaBox)
    guard let pathInPDF = canonicalPath.copy(using: &toPDF) else {
      throw InkSignPdfNativeExporterError.invalidOutput
    }
    let bounds = pathInPDF.boundingBoxOfPath
    guard !bounds.isNull, !bounds.isEmpty,
          bounds.minX.isFinite, bounds.minY.isFinite,
          bounds.width.isFinite, bounds.height.isFinite else {
      throw InkSignPdfNativeExporterError.invalidOutput
    }
    var localize = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
    guard let localPath = pathInPDF.copy(using: &localize) else {
      throw InkSignPdfNativeExporterError.invalidOutput
    }
    return (bounds, localPath)
  }

  private static func pdfBounds(for canonicalBounds: CGRect,
                               in mediaBox: CGRect) -> CGRect {
    CGRect(x: mediaBox.minX + canonicalBounds.minX,
           y: mediaBox.maxY - canonicalBounds.maxY,
           width: canonicalBounds.width,
           height: canonicalBounds.height)
  }

  private static func sameGeometry(_ expected: PageGeometry,
                                   _ actual: PDFPage) -> Bool {
    expected.isValid &&
      PageViewportTransform.normalizedRotation(expected.rotation) ==
        PageViewportTransform.normalizedRotation(actual.rotation) &&
      sameRect(expected.mediaBox, actual.bounds(for: .mediaBox))
  }

  private static func pageBoxesMatch(_ lhs: PDFPage, _ rhs: PDFPage) -> Bool {
    pageBoxes.allSatisfy { sameRect(lhs.bounds(for: $0), rhs.bounds(for: $0)) }
  }

  private static func sameRect(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.01 && abs(lhs.minY - rhs.minY) <= 0.01 &&
      abs(lhs.width - rhs.width) <= 0.01 && abs(lhs.height - rhs.height) <= 0.01
  }
}
