import CoreGraphics
import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules

extension InkSignView {
  func finalize() throws -> Promise<String> {
    let captureResult: Result<ExportSnapshot, Error>
    if Thread.isMainThread {
      captureResult = Result { try captureExportSnapshot() }
    } else {
      var captured: Result<ExportSnapshot, Error>?
      DispatchQueue.main.sync {
        captured = Result { try self.captureExportSnapshot() }
      }
      guard let captured else {
        return Promise.rejected(withError: ExportError.cancelled)
      }
      captureResult = captured
    }
    let snapshot: ExportSnapshot
    switch captureResult {
    case .success(let value):
      snapshot = value
    case .failure(let error):
      return Promise.rejected(withError: error)
    }

    let queue = exportQueue
    return Promise.parallel(queue) { [weak self] in
      guard let owner = self else { throw ExportError.cancelled }
      do {
        var published = false
        defer {
          if !published {
            owner.publicationLock.lock()
            owner.pendingOutputURLs.remove(snapshot.output)
            owner.publicationLock.unlock()
            owner.artifactPolicy.deleteExact(snapshot.output)
          }
        }
        let temporary = try Self.writePDF(
          source: snapshot.source,
          pages: snapshot.pages,
          policy: owner.artifactPolicy)
        defer { owner.artifactPolicy.deleteExact(temporary) }

        owner.publicationLock.lock()
        defer { owner.publicationLock.unlock() }
        guard !owner.disposed, owner.generation == snapshot.generation else {
          owner.pendingOutputURLs.remove(snapshot.output)
          owner.artifactPolicy.deleteExact(snapshot.output)
          throw ExportError.cancelled
        }
        do {
          try Self.publish(temporary: temporary, to: snapshot.output)
        } catch {
          owner.pendingOutputURLs.remove(snapshot.output)
          owner.artifactPolicy.deleteExact(snapshot.output)
          throw error
        }
        owner.pendingOutputURLs.remove(snapshot.output)
        owner.ownedOutputURLs.insert(snapshot.output)
        published = true
        return snapshot.output.path
      } catch {
        throw Self.normalizeExportError(error)
      }
    }
  }

  /// Captures all export inputs on the main-thread-owned document boundary.
  /// The worker must never inspect live document, canvas, or generation state
  /// to decide what request it is exporting.
  func captureExportSnapshot() throws -> ExportSnapshot {
    guard !disposed else { throw ExportError.cancelled }
    guard let state = documentState, !state.pages.isEmpty else {
      throw ExportError.notReady
    }
    let pages = try state.pages.map { page in
      guard page.geometry.isValid,
            let drawing = try? PKDrawing(data: page.history.content.drawing.dataRepresentation()) else {
        throw ExportError.failed
      }
      return ExportPageSnapshot(pageIndex: page.index,
                                geometry: page.geometry,
                                drawing: drawing,
                                textAnnotations: page.history.content.textAnnotations)
    }
    let output: URL
    do {
      output = try artifactPolicy.allocateSignedOutput()
    } catch {
      throw ExportError.failed
    }
    publicationLock.lock()
    pendingOutputURLs.insert(output)
    publicationLock.unlock()
    return ExportSnapshot(source: state.sourceURL,
                          output: output,
                          pages: pages,
                          generation: generation)
  }

  func startDebugRecording() {
    // Android-only diagnostic surface; intentionally no-op on iOS.
  }

  func stopDebugRecording() {
    // Android-only diagnostic surface; intentionally no-op on iOS.
  }

  func exportDebugRecording() throws -> Promise<String> {
    Promise.rejected(withError: ExportError.notReady)
  }

  static func makeInkSnapshot(drawing: PKDrawing,
                              pageSize: CGSize) throws -> InkSnapshot? {
    guard !drawing.strokes.isEmpty else { return nil }
    let pageRect = CGRect(origin: .zero, size: pageSize)
    let inkRect = drawing.bounds.intersection(pageRect)
    guard !inkRect.isNull, !inkRect.isEmpty,
          inkRect.width.isFinite, inkRect.height.isFinite else { return nil }
    let scale = InkSignPdfTextRenderer.exportPixelsPerPageUnit
    let pixelWidth = Int(ceil(inkRect.width * scale))
    let pixelHeight = Int(ceil(inkRect.height * scale))
    guard pixelWidth > 0, pixelHeight > 0,
          pixelWidth <= Int.max / max(pixelHeight, 1),
          pixelWidth * pixelHeight <= InkSignPdfTextRenderer.maximumExportPixels else {
      throw ExportError.failed
    }
    var image: UIImage?
    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
      image = drawing.image(from: inkRect, scale: scale)
    }
    guard let cgImage = image?.cgImage else { throw ExportError.failed }
    return InkSnapshot(image: cgImage, rect: inkRect)
  }

  static func writePDF(source: URL,
                       pages: [ExportPageSnapshot],
                       policy: InkSignPdfCacheArtifactPolicy) throws -> URL {
    let output = try policy.allocateExportScratch()
    defer { policy.deleteExact(output) }
    guard let sourceDocument = CGPDFDocument(source as CFURL),
          let consumer = CGDataConsumer(url: output as CFURL) else {
      throw ExportError.failed
    }
    guard sourceDocument.numberOfPages == pages.count,
          pages.enumerated().allSatisfy({ $0.offset == $0.element.pageIndex }) else {
      throw ExportError.failed
    }
    var context: CGContext?
    for captured in pages {
      guard let sourcePage = sourceDocument.page(at: captured.pageIndex + 1) else {
        throw ExportError.failed
      }
      var box = captured.geometry.mediaBox
      guard let pageContext = context ?? CGContext(consumer: consumer,
                                                     mediaBox: &box,
                                                     auxiliaryInfo: nil) else {
        throw ExportError.failed
      }
      context = pageContext
      pageContext.beginPDFPage([kCGPDFContextMediaBox as String: captured.geometry.mediaBox] as CFDictionary)
      pageContext.saveGState()
      let sourceTransform = sourcePage.getDrawingTransform(
        .mediaBox,
        rect: captured.geometry.mediaBox,
        rotate: Int32(-captured.geometry.rotation),
        preserveAspectRatio: false)
      pageContext.concatenate(sourceTransform)
      pageContext.drawPDFPage(sourcePage)
      pageContext.restoreGState()
      if let ink = try makeInkSnapshot(drawing: captured.drawing,
                                       pageSize: captured.geometry.mediaBox.size) {
        pageContext.saveGState()
        pageContext.translateBy(x: captured.geometry.mediaBox.minX,
                                y: captured.geometry.mediaBox.maxY)
        pageContext.scaleBy(x: 1, y: -1)
        pageContext.interpolationQuality = .high
        pageContext.draw(ink.image, in: ink.rect)
        pageContext.restoreGState()
      }
      try InkSignPdfTextRenderer.drawForPDF(
        captured.textAnnotations,
        pageSize: captured.geometry.mediaBox.size,
        mediaBox: captured.geometry.mediaBox,
        in: pageContext)
      pageContext.endPDFPage()
    }
    context?.closePDF()

    guard let rewritten = PDFDocument(url: output),
          rewritten.pageCount == pages.count else {
      throw ExportError.failed
    }
    for captured in pages {
      let outputPage = rewritten.page(at: captured.pageIndex)
      outputPage.rotation = captured.geometry.rotation
    }
    let verified = try policy.allocateVerificationScratch()
    var verifiedSucceeded = false
    defer {
      if !verifiedSucceeded { policy.deleteExact(verified) }
    }
    guard rewritten.write(to: verified),
          let verifiedDocument = PDFDocument(url: verified),
          verifiedDocument.pageCount == pages.count else {
      throw ExportError.failed
    }
    for captured in pages {
      let verifiedPage = verifiedDocument.page(at: captured.pageIndex)
      guard normalizedRotation(verifiedPage.rotation) == normalizedRotation(captured.geometry.rotation),
            boxesMatch(verifiedPage.bounds(for: .mediaBox), captured.geometry.mediaBox) else {
        throw ExportError.failed
      }
    }
    verifiedSucceeded = true
    return verified
  }

  static func publish(temporary: URL, to output: URL) throws {
    if FileManager.default.fileExists(atPath: output.path) {
      _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: output)
    }
  }

  static func normalizedRotation(_ value: Int) -> Int {
    let remainder = value % 360
    return remainder >= 0 ? remainder : remainder + 360
  }

  private static func boxesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    let epsilon: CGFloat = 0.001
    return abs(lhs.minX - rhs.minX) <= epsilon &&
      abs(lhs.minY - rhs.minY) <= epsilon &&
      abs(lhs.width - rhs.width) <= epsilon &&
      abs(lhs.height - rhs.height) <= epsilon
  }

  private static func normalizeExportError(_ error: Error) -> Error {
    if let exportError = error as? ExportError {
      return exportError
    }
    return ExportError.failed
  }
}

struct InkSnapshot {
  let image: CGImage
  let rect: CGRect
}

struct ExportPageSnapshot {
  let pageIndex: Int
  let geometry: PageGeometry
  let drawing: PKDrawing
  let textAnnotations: [InkSignPdfTextAnnotation]
}

struct ExportSnapshot {
  let source: URL
  let output: URL
  let pages: [ExportPageSnapshot]
  let generation: UInt64
}
