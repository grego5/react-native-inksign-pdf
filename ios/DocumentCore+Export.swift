import Foundation
import PencilKit
import NitroModules

extension DocumentCore {
  func finalize() -> Promise<String> {
    submit { try self.finalizeNow() }
  }

  private func finalizeNow() throws -> Promise<String> {
    endTextEdit()
    guard let operation = coordinator.admit(.finalize) else {
      return Promise.rejected(withError: InkSignPdfExportError.operationInProgress)
    }
    let settlement = InkSignPdfOperationPromise<String>()
    guard coordinator.registerCancellation(for: operation, handler: {
      settlement.reject(InkSignPdfExportError.cancelled)
    }) else {
      settlement.reject(InkSignPdfExportError.cancelled)
      return settlement.promise
    }
    let captureResult: Result<ExportSnapshot, Swift.Error> = Result { try captureExportSnapshot(operation: operation) }

    let snapshot: ExportSnapshot
    switch captureResult {
    case .success(let value):
      snapshot = value
    case .failure(let error):
      coordinator.settle(operation)
      settlement.reject(error)
      return settlement.promise
    }

    let coordinator = self.coordinator
    coordinator.pdfQueue.async {
      var outputPublished = false
      let result: Result<String, Swift.Error>
      do {
        try FileManager.default.copyItem(at: snapshot.source, to: snapshot.sourceSnapshot)
        let temporary = try Self.writePDF(source: snapshot.sourceSnapshot,
                                          pages: snapshot.pages,
                                          policy: coordinator.artifactPolicy)
        defer { coordinator.artifactPolicy.deleteExact(temporary) }
        let didPublish = try coordinator.publishOutput(snapshot.output,
                                                       token: snapshot.operation) {
          try Self.publish(temporary: temporary, to: snapshot.output)
        }
        guard didPublish else { throw InkSignPdfExportError.cancelled }
        outputPublished = true
        result = .success(snapshot.output.absoluteString)
      } catch {
        result = .failure(coordinator.isCurrent(snapshot.operation)
                          ? Self.normalizeExportError(error)
                          : InkSignPdfExportError.cancelled)
      }
      coordinator.discardArtifact(snapshot.sourceSnapshot)
      if !outputPublished { coordinator.discardArtifact(snapshot.output) }
      DispatchQueue.main.async {
        guard coordinator.isCurrent(snapshot.operation) else {
          settlement.reject(InkSignPdfExportError.cancelled)
          return
        }
        switch result {
        case .success(let path):
          coordinator.finish(snapshot.operation)
          settlement.resolve(path)
        case .failure(let error):
          coordinator.settle(snapshot.operation)
          settlement.reject(error)
        }
      }
    }
    return settlement.promise
  }

  /// Captures committed document content on the main-thread-owned state
  /// boundary. The worker receives values and drawing data only.
  func captureExportSnapshot(
    operation: InkSignPdfDocumentCoordinator.OperationToken
  ) throws -> ExportSnapshot {
    guard coordinator.isCurrent(operation) else { throw InkSignPdfExportError.cancelled }
    guard let state = coordinator.document, !state.pages.isEmpty else {
      throw InkSignPdfExportError.notReady
    }
    let pages = state.pages.enumerated().map { pageIndex, page in
      ExportPageSnapshot(pageIndex: pageIndex,
                         pageID: page.id,
                         geometry: page.geometry,
                         drawingData: page.history.content.drawing.dataRepresentation(),
                         textAnnotations: page.history.content.textAnnotations,
                         sourceGeometry: page.sourceGeometry)
    }
    let artifacts: (source: URL, output: URL)
    do {
      artifacts = try coordinator.allocateExportArtifacts(for: operation)
    } catch {
      throw InkSignPdfExportError.failed
    }
    return ExportSnapshot(source: state.workingURL,
                          sourceSnapshot: artifacts.source,
                          output: artifacts.output,
                          pages: pages,
                          operation: operation)
  }

  static func writePDF(source: URL,
                       pages: [ExportPageSnapshot],
                       policy: InkSignPdfCacheArtifactPolicy) throws -> URL {
    let output = try policy.allocateExportScratch()
    do {
      try InkSignPdfPdfiumExporter.write(sourceURL: source,
                                         pages: pages,
                                         outputURL: output,
                                         validatePDFKit: false)
      return output
    } catch InkSignPdfPdfiumExporterError.unsupportedInk(_) {
      policy.deleteExact(output)
      throw InkSignPdfExportError.unsupportedContent
    } catch {
      policy.deleteExact(output)
      throw normalizeExportError(error)
    }
  }

  static func publish(temporary: URL, to output: URL) throws {
    if FileManager.default.fileExists(atPath: output.path) {
      _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: output)
    }
  }

  private static func normalizeExportError(_ error: Swift.Error) -> Swift.Error {
    if let exportError = error as? InkSignPdfExportError { return exportError }
    let native = error as NSError
    if native.domain == "InkSignPdf.Export" || native.domain == "InkSignPdf.Pdfium" {
      return error
    }
    return InkSignPdfExportError.failed
  }
}

struct ExportPageSnapshot {
  let pageIndex: Int
  let pageID: UUID
  let geometry: PageGeometry
  let drawingData: Data
  let textAnnotations: [InkSignPdfTextAnnotation]
  var sourceGeometry: PageGeometry? = nil
}

struct ExportSnapshot {
  let source: URL
  let sourceSnapshot: URL
  let output: URL
  let pages: [ExportPageSnapshot]
  let operation: InkSignPdfDocumentCoordinator.OperationToken
}
