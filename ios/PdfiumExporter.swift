import CoreGraphics
import Foundation
import PDFKit
import PencilKit
import UIKit

enum InkSignPdfPdfiumExporterError: LocalizedError {
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

/// Writes committed canonical content into a detached PDFium document.
enum InkSignPdfPdfiumExporter {
  static func write(sourceURL: URL, pages: [ExportPageSnapshot], outputURL: URL,
                    validatePDFKit: Bool) throws {
    let source = try stage("source_read") { try Data(contentsOf: sourceURL) }
    let metadata = try stage("source_inspection") { try InkSignPdfPdfiumBackend.inspect(data: source) }
    guard !pages.isEmpty, metadata.count == pages.count,
          pages.enumerated().allSatisfy({ $0.offset == $0.element.pageIndex }) else {
      throw InkSignPdfPdfiumExporterError.invalidPageOrder
    }
    let resources = InkSignPdfCoreTextExportResources()
    var runs: [InkSignPdfPdfiumExportRun] = []
    var paths: [InkSignPdfPdfiumExportPath] = []
    var lineID = 0
    for snapshot in pages {
      let page = metadata[snapshot.pageIndex]
      let expected = snapshot.sourceGeometry ?? snapshot.geometry
      guard sameRect(page.mediaBox, expected.mediaBox),
            sameRect(page.visibleBox, expected.visibleBox), page.rotation == expected.rotation else {
        throw InkSignPdfPdfiumExporterError.invalidOutput("source geometry differs from captured state")
      }
      for annotation in snapshot.textAnnotations {
        let layout = try stage("text_resources") {
          try resources.prepare(annotation, pageSize: page.visibleBox.size)
        }
        let color = try argb(layout.color)
        for line in layout.lines {
          for (order, prepared) in line.runs.enumerated() {
            let run = InkSignPdfPdfiumExportRun()
            run.pageIndex = snapshot.pageIndex
            run.lineID = lineID
            run.lineText = line.text
            run.sourceRange = prepared.sourceRange
            run.rightToLeft = prepared.isRTL
            run.baseRightToLeft = layout.isRTL
            run.visualOrder = order
            run.fontIndex = prepared.fontIndex
            run.fontSize = prepared.fontSize
            run.color = color
            run.transform = layout.transform
            run.hasClip = layout.clip != nil
            run.clip = layout.clip ?? .zero
            run.glyphs = prepared.glyphs.map { value in
              let glyph = InkSignPdfPdfiumExportGlyph()
              glyph.glyphID = UInt32(value.glyphID)
              glyph.sourceOffset = value.sourceOffset
              glyph.unicode = value.unicode
              glyph.position = value.position
              return glyph
            }
            runs.append(run)
          }
          lineID += 1
        }
      }
      guard let drawing = try? PKDrawing(data: snapshot.drawingData) else {
        throw InkSignPdfPdfiumExporterError.unsupportedInk("committed drawing is unreadable")
      }
      do {
        for stroke in try InkSignPdfSignatureVectorPath.filledStrokes(in: drawing) {
          paths.append(try exportPath(stroke, pageIndex: snapshot.pageIndex))
        }
      } catch {
        throw InkSignPdfPdfiumExporterError.unsupportedInk(String(describing: error))
      }
    }
    let output = try stage("pdfium_serialization") {
      try InkSignPdfPdfiumBackend.write(data: source, pages: metadata,
        rotations: pages.map { NSNumber(value: $0.geometry.rotation) },
        paths: paths, runs: runs, fonts: resources.fonts)
    }
    try stage("output_write") { try output.write(to: outputURL, options: .atomic) }
    guard validatePDFKit else { return }
    // Tests can additionally verify interoperability with the PDFKit viewer.
    guard let original = PDFDocument(data: source), let reopened = PDFDocument(url: outputURL),
          reopened.pageCount == pages.count else {
      throw InkSignPdfPdfiumExporterError.writeFailed
    }
    for snapshot in pages {
      guard let before = original.page(at: snapshot.pageIndex),
            let after = reopened.page(at: snapshot.pageIndex),
            after.rotation == snapshot.geometry.rotation,
            sameRect(after.bounds(for: .mediaBox), snapshot.geometry.mediaBox),
            [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox].allSatisfy({
              sameRect(before.bounds(for: $0), after.bounds(for: $0))
            }), sourceAnnotationsMatch(before.annotations, after.annotations) else {
        throw InkSignPdfPdfiumExporterError.invalidOutput("PDFKit reopened page geometry differs")
      }
    }
  }

  private static func argb(_ value: String) throws -> UInt32 {
    guard value.count == 7, value.first == "#", let rgb = UInt32(value.dropFirst(), radix: 16) else {
      throw InkSignPdfPdfiumExporterError.invalidOutput("invalid text color")
    }
    return 0xff000000 | rgb
  }

  private static func stage<T>(_ name: String, _ operation: () throws -> T) throws -> T {
    do { return try operation() }
    catch {
      let underlying = error as NSError
      var info = underlying.userInfo
      info[NSLocalizedDescriptionKey] = "export_\(name): \(underlying.localizedDescription)"
      info[NSUnderlyingErrorKey] = underlying
      info["exportStage"] = name
      // Keep native error domain/code and source information for callers.
      throw NSError(domain: underlying.domain, code: underlying.code, userInfo: info)
    }
  }

  private static func exportPath(_ stroke: InkSignPdfFilledStroke,
                                 pageIndex: Int) throws -> InkSignPdfPdfiumExportPath {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard stroke.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha == 1 else {
      throw InkSignPdfPdfiumExporterError.unsupportedInk("unsupported stroke color")
    }
    let path = InkSignPdfPdfiumExportPath()
    path.pageIndex = pageIndex
    path.color = 0xff000000 | (UInt32((red * 255).rounded()) << 16) |
      (UInt32((green * 255).rounded()) << 8) | UInt32((blue * 255).rounded())
    var types: [NSNumber] = []
    var coordinates: [NSNumber] = []
    var current = CGPoint.zero
    var start = CGPoint.zero
    func append(_ type: Int, _ points: [CGPoint]) {
      types.append(NSNumber(value: type))
      for index in 0..<3 {
        let point = index < points.count ? points[index] : .zero
        coordinates.append(NSNumber(value: Double(point.x)))
        coordinates.append(NSNumber(value: Double(point.y)))
      }
    }
    stroke.path.applyWithBlock { pointer in
      let element = pointer.pointee
      switch element.type {
      case .moveToPoint:
        current = element.points[0]; start = current
        append(0, [current])
      case .addLineToPoint:
        current = element.points[0]
        append(1, [current])
      case .addQuadCurveToPoint:
        let control = element.points[0], end = element.points[1]
        let first = CGPoint(x: current.x + (control.x - current.x) * 2 / 3,
                            y: current.y + (control.y - current.y) * 2 / 3)
        let second = CGPoint(x: end.x + (control.x - end.x) * 2 / 3,
                             y: end.y + (control.y - end.y) * 2 / 3)
        append(2, [first, second, end]); current = end
      case .addCurveToPoint:
        append(2, [element.points[0], element.points[1], element.points[2]])
        current = element.points[2]
      case .closeSubpath:
        append(3, []); current = start
      @unknown default:
        break
      }
    }
    path.commandTypes = types
    path.coordinates = coordinates
    return path
  }

  private static func sameRect(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.01 && abs(lhs.minY - rhs.minY) <= 0.01 &&
      abs(lhs.width - rhs.width) <= 0.01 && abs(lhs.height - rhs.height) <= 0.01
  }

  private static func sourceAnnotationsMatch(_ before: [PDFAnnotation],
                                             _ after: [PDFAnnotation]) -> Bool {
    guard before.count == after.count else { return false }
    var remaining = after
    for annotation in before {
      guard let index = remaining.firstIndex(where: {
        $0.type == annotation.type && sameRect($0.bounds, annotation.bounds) &&
          $0.contents == annotation.contents
      }) else { return false }
      remaining.remove(at: index)
    }
    return true
  }
}
