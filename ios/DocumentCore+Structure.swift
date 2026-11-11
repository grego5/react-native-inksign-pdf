import Foundation
import NitroModules

struct InkSignPdfStructuralCommit {
  let document: CommittedDocumentState
  let generation: UInt64
  let addedCount: Int
}

extension DocumentCore {
  func commitStructureNow(_ input: InkSignPdfDocumentCoordinator.StructuralInput,
                          staged: [InkSignPdfStagedPageInput],
                          command: InkSignPdfDocumentCoordinator.StructuralCommand,
                          initialImport: Bool = false) -> Promise<InkSignPdfStructuralCommit> {
      let settlement = InkSignPdfOperationPromise<InkSignPdfStructuralCommit>()
      let coordinator = self.coordinator
      coordinator.pdfQueue.async {
        defer { coordinator.releaseStagedInputs(staged) }
        let candidate: Result<CommittedDocumentState, Swift.Error> = Result {
          try coordinator.assembleCandidate(input, staged: staged, command: command)
        }
        DispatchQueue.main.async {
          switch candidate {
          case .failure(let error):
            coordinator.settle(input.operation)
            self.changed(.structure)
            settlement.reject(error)
          case .success(let document):
            guard coordinator.isCurrent(input.operation) else {
              coordinator.discardCandidate(document)
              coordinator.settle(input.operation)
              settlement.reject(Error.closed)
              return
            }
            if case .restore = command { document.pages.forEach { $0.history.revertChanges() } }
            let previous: CommittedDocumentState?
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
            if initialImport { coordinator.setStructuralDirty(false); coordinator.acceptBaseline() }
            if case .restore = command { coordinator.setStructuralDirty(false) }
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
