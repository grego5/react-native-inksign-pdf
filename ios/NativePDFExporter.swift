import CoreGraphics
import Foundation
import PDFKit
import PencilKit

enum InkSignPdfNativeExporterError: LocalizedError {
  case unreadableSource
  case invalidPageOrder
  case unsupportedInk(String)
  case writeFailed
  case invalidOutput(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedInk(let reason):
      return "PDF signature vectorization failed: \(reason)"
    case .invalidOutput(let reason):
      return "PDF export validation failed: \(reason)"
    default:
      return nil
    }
  }
}

/// Adds editor content to the source pages as PDF annotations, then verifies
/// the written document and each module-owned appearance stream.
enum InkSignPdfNativeExporter {
  static let signatureAppearanceMargin: CGFloat = 0.5

  private struct ModuleAnnotationExpectations {
    let text: [InkSignPdfTextAnnotation]
    let signatureBounds: [CGRect]
  }

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

    var sourceAnnotations: [Int: [PDFAnnotation]] = [:]
    var moduleAnnotations: [Int: ModuleAnnotationExpectations] = [:]
    for snapshot in pages {
      guard let page = document.page(at: snapshot.pageIndex),
            sameGeometry(snapshot.geometry, page) else {
        throw InkSignPdfNativeExporterError.invalidOutput(
          "source page geometry differs from the captured page state")
      }
      sourceAnnotations[snapshot.pageIndex] = page.annotations
      for text in snapshot.textAnnotations {
        guard let color = InkSignPdfTextRenderer.color(from: text.textColor) else {
          throw InkSignPdfNativeExporterError.invalidOutput(
            "text annotation color cannot be represented")
        }
        page.addAnnotation(InkSignPdfVectorAnnotation(
          text: text,
          mediaBox: snapshot.geometry.mediaBox,
          pdfBounds: pdfBounds(for: text.bounds, in: snapshot.geometry.mediaBox),
          color: color))
      }

      guard let drawing = try? PKDrawing(data: snapshot.drawingData) else {
        throw InkSignPdfNativeExporterError.unsupportedInk("committed drawing data is unreadable")
      }
      let strokes: [InkSignPdfFilledStroke]
      do {
        strokes = try InkSignPdfSignatureVectorPath.filledStrokes(in: drawing)
      } catch {
        throw InkSignPdfNativeExporterError.unsupportedInk(String(describing: error))
      }
      var signatureBounds: [CGRect] = []
      signatureBounds.reserveCapacity(strokes.count)
      for stroke in strokes {
        let (bounds, localPath) = try pdfPath(stroke.path,
                                              mediaBox: snapshot.geometry.mediaBox)
        page.addAnnotation(InkSignPdfVectorAnnotation(
          signatureBounds: bounds,
          localPath: localPath,
          color: stroke.color,
          mediaBox: snapshot.geometry.mediaBox))
        signatureBounds.append(bounds)
      }
      moduleAnnotations[snapshot.pageIndex] = ModuleAnnotationExpectations(
        text: snapshot.textAnnotations,
        signatureBounds: signatureBounds)
    }

    guard document.write(to: outputURL),
          let reopened = PDFDocument(url: outputURL),
          reopened.pageCount == document.pageCount else {
      throw InkSignPdfNativeExporterError.writeFailed
    }
    try validate(source: document,
                 output: reopened,
                 pages: pages,
                 sourceAnnotations: sourceAnnotations,
                 moduleAnnotations: moduleAnnotations)
  }

  private static func validate(source: PDFDocument,
                               output: PDFDocument,
                               pages: [ExportPageSnapshot],
                               sourceAnnotations: [Int: [PDFAnnotation]],
                               moduleAnnotations: [Int: ModuleAnnotationExpectations]) throws {
    for snapshot in pages {
      guard let sourcePage = source.page(at: snapshot.pageIndex),
            let outputPage = output.page(at: snapshot.pageIndex),
            sameGeometry(snapshot.geometry, outputPage),
            pageBoxesMatch(sourcePage, outputPage) else {
        throw InkSignPdfNativeExporterError.invalidOutput(
          "reopened page geometry or boxes differ from the source")
      }
      let expected = moduleAnnotations[snapshot.pageIndex]!
      let beforeExport = sourceAnnotations[snapshot.pageIndex] ?? []
      let exportedAnnotations = outputPage.annotations

      for (index, text) in expected.text.enumerated() {
        let bounds = pdfBounds(for: text.bounds, in: snapshot.geometry.mediaBox)
        let matches: (PDFAnnotation) -> Bool = {
          $0.type?.caseInsensitiveCompare("FreeText") == .orderedSame &&
            $0.contents == text.text && sameRect($0.bounds, bounds)
        }
        let duplicateCount = expected.text[..<index].filter {
          $0.text == text.text && sameRect(
            pdfBounds(for: $0.bounds, in: snapshot.geometry.mediaBox), bounds)
        }.count
        let sourceCount = beforeExport.filter {
          matches($0) && hasPersistedAppearance($0, flags: InkSignPdfVectorAnnotation.textFlags)
        }.count
        let outputCount = exportedAnnotations.filter {
          matches($0) && hasPersistedAppearance($0, flags: InkSignPdfVectorAnnotation.textFlags)
        }.count
        guard outputCount > sourceCount + duplicateCount else {
          throw InkSignPdfNativeExporterError.invalidOutput(
            "text annotation \(text.id) was not persisted with its appearance and locked-content flags")
        }
      }

      for (index, bounds) in expected.signatureBounds.enumerated() {
        let matches: (PDFAnnotation) -> Bool = {
          $0.type?.caseInsensitiveCompare("Stamp") == .orderedSame &&
            sameRect($0.bounds, bounds)
        }
        let duplicateCount = expected.signatureBounds[..<index].filter {
          sameRect($0, bounds)
        }.count
        let sourceCount = beforeExport.filter {
          matches($0) && hasPersistedAppearance($0, flags: InkSignPdfVectorAnnotation.signatureFlags)
        }.count
        let outputCount = exportedAnnotations.filter {
          matches($0) && hasPersistedAppearance($0, flags: InkSignPdfVectorAnnotation.signatureFlags)
        }.count
        guard outputCount > sourceCount + duplicateCount else {
          throw InkSignPdfNativeExporterError.invalidOutput(
            "signature vector annotation was not persisted with its appearance and locked flags")
        }
      }
    }
  }

  private static func hasPersistedAppearance(_ annotation: PDFAnnotation,
                                             flags: Int) -> Bool {
    annotation.hasAppearanceStream && annotation.shouldDisplay && annotation.shouldPrint &&
      InkSignPdfVectorAnnotation.flags(of: annotation) & flags == flags
  }

  private static func pdfPath(_ canonicalPath: CGPath,
                              mediaBox: CGRect) throws -> (CGRect, CGPath) {
    var toPDF = InkSignPdfTextRenderer.canonicalToPDFTransform(for: mediaBox)
    guard let pathInPDF = canonicalPath.copy(using: &toPDF) else {
      throw InkSignPdfNativeExporterError.invalidOutput(
        "signature path could not be transformed to PDF coordinates")
    }
    let pathBounds = pathInPDF.boundingBoxOfPath
    guard !pathBounds.isNull, !pathBounds.isEmpty,
          pathBounds.minX.isFinite, pathBounds.minY.isFinite,
          pathBounds.width.isFinite, pathBounds.height.isFinite else {
      throw InkSignPdfNativeExporterError.invalidOutput(
        "signature path has invalid PDF bounds")
    }
    let bounds = pathBounds.insetBy(dx: -signatureAppearanceMargin,
                                    dy: -signatureAppearanceMargin)
    guard bounds.minX.isFinite, bounds.minY.isFinite,
          bounds.width.isFinite, bounds.height.isFinite else {
      throw InkSignPdfNativeExporterError.invalidOutput(
        "signature annotation bounds are invalid")
    }
    var localize = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
    guard let localPath = pathInPDF.copy(using: &localize) else {
      throw InkSignPdfNativeExporterError.invalidOutput(
        "signature path could not be localized to its annotation bounds")
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
