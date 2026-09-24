import Foundation
import PencilKit
import NitroModules

extension InkSignView {
  func finalize() throws -> Promise<String> {
    guard let operation = documentCoordinator.admit(.finalize) else {
      return Promise.rejected(withError: ExportError.operationInProgress)
    }
    let captureResult: Result<ExportSnapshot, Error>
    if Thread.isMainThread {
      captureResult = Result { try captureExportSnapshot(operation: operation) }
    } else {
      var captured: Result<ExportSnapshot, Error>?
      DispatchQueue.main.sync {
        captured = Result { try self.captureExportSnapshot(operation: operation) }
      }
      guard let captured else {
        documentCoordinator.finish(operation)
        return Promise.rejected(withError: ExportError.cancelled)
      }
      captureResult = captured
    }

    let snapshot: ExportSnapshot
    switch captureResult {
    case .success(let value):
      snapshot = value
    case .failure(let error):
      documentCoordinator.finish(operation)
      return Promise.rejected(withError: error)
    }

    let coordinator = documentCoordinator
    return Promise.parallel(coordinator.pdfQueue) {
      defer { coordinator.finish(snapshot.operation) }
      var outputPublished = false
      defer {
        coordinator.discardArtifact(snapshot.sourceSnapshot)
        if !outputPublished { coordinator.discardArtifact(snapshot.output) }
      }
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
        guard didPublish else { throw ExportError.cancelled }
        outputPublished = true
        return snapshot.output.path
      } catch {
        guard coordinator.isCurrent(snapshot.operation) else { throw ExportError.cancelled }
        throw Self.normalizeExportError(error)
      }
    }
  }

  /// Captures committed document content on the main-thread-owned state
  /// boundary. The worker receives values and drawing data only.
  func captureExportSnapshot(
    operation: InkSignPdfDocumentCoordinator.OperationToken
  ) throws -> ExportSnapshot {
    guard !disposed else { throw ExportError.cancelled }
    guard documentCoordinator.isCurrent(operation) else { throw ExportError.cancelled }
    guard let state = documentCoordinator.document, !state.pages.isEmpty else {
      throw ExportError.notReady
    }
    let pages = state.pages.enumerated().map { pageIndex, page in
      ExportPageSnapshot(pageIndex: pageIndex,
                         pageID: page.id,
                         geometry: page.geometry,
                         drawingData: page.history.content.drawing.dataRepresentation(),
                         textAnnotations: page.history.content.textAnnotations)
    }
    let artifacts: (source: URL, output: URL)
    do {
      artifacts = try documentCoordinator.allocateExportArtifacts(for: operation)
    } catch {
      throw ExportError.failed
    }
    return ExportSnapshot(source: state.workingURL,
                          sourceSnapshot: artifacts.source,
                          output: artifacts.output,
                          pages: pages,
                          operation: operation)
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

  static func writePDF(source: URL,
                       pages: [ExportPageSnapshot],
                       policy: InkSignPdfCacheArtifactPolicy) throws -> URL {
    let output = try policy.allocateExportScratch()
    do {
      try InkSignPdfNativeExporter.write(sourceURL: source,
                                         pages: pages,
                                         outputURL: output)
      return output
    } catch InkSignPdfNativeExporterError.unsupportedInk {
      policy.deleteExact(output)
      throw ExportError.unsupportedContent
    } catch {
      policy.deleteExact(output)
      throw ExportError.failed
    }
  }

  static func publish(temporary: URL, to output: URL) throws {
    if FileManager.default.fileExists(atPath: output.path) {
      _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: output)
    }
  }

  private static func normalizeExportError(_ error: Error) -> Error {
    if let exportError = error as? ExportError { return exportError }
    return ExportError.failed
  }
}

struct ExportPageSnapshot {
  let pageIndex: Int
  let pageID: UUID
  let geometry: PageGeometry
  let drawingData: Data
  let textAnnotations: [InkSignPdfTextAnnotation]
}

struct ExportSnapshot {
  let source: URL
  let sourceSnapshot: URL
  let output: URL
  let pages: [ExportPageSnapshot]
  let operation: InkSignPdfDocumentCoordinator.OperationToken
}
