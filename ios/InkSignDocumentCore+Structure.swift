import Foundation
import NitroModules

struct InkSignPdfStructuralCommit {
  let document: InkSignPdfDocumentState
  let generation: UInt64
  let addedCount: Int
}

extension InkSignDocumentCore {
  func commitStagedPages(_ staged: [InkSignPdfStagedPageInput],
                        command: InkSignPdfDocumentCoordinator.StructuralCommand,
                        generation: UInt64, targetPageID: UUID?,
                        imageGeometry: PageGeometry, targetDpi: Double?,
                        jpegQuality: Double?, tag: String?) -> Promise<InkSignPdfStructuralCommit> {
    submit(onDiscard: {
      self.coordinator.pdfQueue.async { self.coordinator.releaseStagedInputs(staged) }
    }) {
      if let tag, tag.isEmpty {
        self.coordinator.pdfQueue.async { self.coordinator.releaseStagedInputs(staged) }
        return .rejected(withError: TextError.invalidPageTag)
      }
      guard self.coordinator.generation == generation,
            targetPageID == nil || self.coordinator.document?.index(of: targetPageID!) != nil else {
        self.coordinator.pdfQueue.async { self.coordinator.releaseStagedInputs(staged) }
        return .rejected(withError: MutablePageError.operationCancelled)
      }
      guard let operation = self.coordinator.admit(.structural) else {
        self.coordinator.pdfQueue.async { self.coordinator.releaseStagedInputs(staged) }
        return .rejected(withError: MutablePageError.operationInProgress)
      }
      let state = self.coordinator.document
      let index = targetPageID.flatMap { state?.index(of: $0) } ?? 0
      let input = InkSignPdfDocumentCoordinator.StructuralInput(operation: operation,
        document: state, pages: state?.pages ?? [], targetPageID: targetPageID ?? UUID(),
        targetPageIndex: index, imageGeometry: imageGeometry,
        imageTargetDpi: targetDpi, imageJpegQuality: jpegQuality,
        recordHistory: self.recordHistory, tag: tag)
      return self.commitStructureNow(input, staged: staged, command: command)
    }
  }

  func commitStructureNow(_ input: InkSignPdfDocumentCoordinator.StructuralInput,
                          staged: [InkSignPdfStagedPageInput],
                          command: InkSignPdfDocumentCoordinator.StructuralCommand) -> Promise<InkSignPdfStructuralCommit> {
      let settlement = InkSignPdfOperationPromise<InkSignPdfStructuralCommit>()
      let coordinator = self.coordinator
      coordinator.pdfQueue.async {
        defer { coordinator.releaseStagedInputs(staged) }
        let candidate: Result<InkSignPdfDocumentState, Swift.Error> = Result {
          try coordinator.assembleCandidate(input, staged: staged, command: command)
        }
        DispatchQueue.main.async {
          switch candidate {
          case .failure(let error):
            coordinator.settle(input.operation)
            settlement.reject(error)
          case .success(let document):
            let previous: InkSignPdfDocumentState?
            let published: Bool
            if input.document == nil {
              previous = nil
              published = coordinator.publishInitialStructural(document, operation: input.operation)
            } else {
              previous = coordinator.publishStructural(document, operation: input.operation)
              published = previous != nil
            }
            guard published else {
              coordinator.discardCandidate(document)
              coordinator.settle(input.operation)
              settlement.reject(Error.closed)
              return
            }
            // Presentation does not own mutation success or the core FIFO slot.
            if let previous { coordinator.workingArtifacts.retire(previous.workingURL) }
            coordinator.settle(input.operation)
            self.changed(.structure)
            settlement.resolve(InkSignPdfStructuralCommit(document: document,
              generation: coordinator.generation,
              addedCount: document.pages.count - input.pages.count))
          }
        }
      }
      return settlement.promise
  }
}
