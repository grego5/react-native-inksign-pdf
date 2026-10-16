import Foundation
import CoreGraphics
import NitroModules

extension DocumentCore {
  private func prepareOpenNow(sourceURL: URL,
                             operation: InkSignPdfDocumentCoordinator.OperationToken,
                             imageGeometry: PageGeometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 595.28, height: 841.89), rotation: 0),
                             targetDpi: Double? = nil, jpegQuality: Double? = nil,
                             tag: String? = nil) -> Promise<CommittedDocumentState> {
      let settlement = InkSignPdfOperationPromise<CommittedDocumentState>()
      let coordinator = self.coordinator
      coordinator.pdfQueue.async {
        let result: Result<CommittedDocumentState, Swift.Error>
        var artifact: URL?
        do {
          guard coordinator.isCurrent(operation) else {
            throw InkSignPdfLoadError.cancelled
          }
          var directory: ObjCBool = false
          guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &directory),
                !directory.boolValue, FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw InkSignPdfLoadError.invalidSource
          }
          let source = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
          let working = try coordinator.artifactPolicy.allocateWorkingSource()
          artifact = working
          guard coordinator.registerPendingArtifact(working, for: operation) else {
            throw InkSignPdfLoadError.cancelled
          }
          if source.starts(with: [0xff, 0xd8, 0xff]) {
            let image = try InkSignPdfImagePageEncoder.encode(sourceURL, geometry: imageGeometry,
                                                                      targetDpi: targetDpi, jpegQuality: jpegQuality)
            _ = try InkSignPdfPdfiumBackend.assemble(data: nil, operation: .create,
              inputs: [image.nativeInput], pageIndex: 0, destinationIndex: 0, outputURL: working)
          } else {
            try source.write(to: working, options: .atomic)
          }
          let candidate = try InkSignPdfDocumentCandidateLoader.load(url: working,
                                                                     recordHistory: self.recordHistory, tag: tag)
          result = .success(CommittedDocumentState(sourceURL: sourceURL, workingURL: working,
            pages: candidate.pages))
        } catch {
          if let artifact { coordinator.discardArtifact(artifact) }
          result = .failure(error)
        }
        DispatchQueue.main.async {
          guard coordinator.isCurrent(operation) else {
            if case .success(let state) = result { coordinator.discardArtifact(state.workingURL) }
            settlement.reject(InkSignPdfLoadError.cancelled)
            return
          }
          switch result {
          case .success(let state): settlement.resolve(state)
          case .failure(let error): settlement.reject(error)
          }
        }
      }
      return settlement.promise
  }

  func open(sourceURL: URL,
            imageGeometry: PageGeometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 595.28, height: 841.89), rotation: 0),
            targetDpi: Double? = nil, jpegQuality: Double? = nil, tag: String? = nil) -> Promise<CommittedDocumentState> {
    submit {
      try Self.validateTag(tag)
      guard let operation = self.coordinator.admit(.open) else {
        return Promise.rejected(withError: InkSignPdfLoadError.cancelled)
      }
      let result = InkSignPdfOperationPromise<CommittedDocumentState>()
      self.prepareOpenNow(sourceURL: sourceURL, operation: operation, imageGeometry: imageGeometry,
        targetDpi: targetDpi, jpegQuality: jpegQuality, tag: tag).then { state in
        guard self.coordinator.publish(state, operation: operation) else {
          self.coordinator.discardArtifact(state.workingURL)
          self.coordinator.settle(operation)
          result.reject(InkSignPdfLoadError.cancelled)
          return
        }
        self.coordinator.settle(operation)
        self.changed(.document)
        result.resolve(state)
      }.catch { error in
        self.coordinator.settle(operation)
        result.reject(error)
      }
      return result.promise
    }
  }
}
