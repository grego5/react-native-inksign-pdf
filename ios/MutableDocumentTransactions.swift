import CoreGraphics
import Foundation
import NitroModules
import PDFKit

extension InkSignPdfDocumentCoordinator {
  enum StructuralCommand { case append, remove, move(to: Int) }

  struct StructuralInput {
    let operation: OperationToken
    let document: InkSignPdfDocumentState?
    let pages: [InkSignPdfPageState]
    let activePageID: UUID
    let activePageIndex: Int
    let imageGeometry: PageGeometry
    let fallbackFont: PdfFallbackFont?
  }

  func assembleCandidate(_ input: StructuralInput,
                         staged: [InkSignPdfStagedPageInput],
                         command: StructuralCommand) throws -> InkSignPdfDocumentState {
    guard isCurrent(input.operation) else { throw InkSignView.MutablePageError.operationCancelled }
    let allocated = try artifactPolicy.allocateWorkingSource()
    guard registerPendingArtifact(allocated, for: input.operation) else {
      artifactPolicy.deleteExact(allocated)
      throw InkSignView.MutablePageError.operationCancelled
    }
    var candidateSession: InkSignPdfPdfiumSession?
    do {
      let source: Data
      if let document = input.document {
        source = try Data(contentsOf: document.workingURL, options: [.mappedIfSafe])
      } else {
        source = Data()
      }
      var appendInputs: [[String: Any]] = []
      if case .append = command {
        for stagedInput in staged {
          if stagedInput.type == .pdf {
            appendInputs.append(["type": "pdf",
                                 "data": try Data(contentsOf: stagedInput.url, options: [.mappedIfSafe])])
          } else {
            appendInputs.append(try InkSignPdfMutablePageImageEncoder.encode(
              stagedInput.url, geometry: input.imageGeometry))
          }
        }
      }
      let operationValue: Int
      let destination: Int
      switch command {
      case .append: operationValue = 0; destination = 0
      case .remove: operationValue = 1; destination = 0
      case .move(let target): operationValue = 2; destination = target
      }
      let pageSizes: [NSValue]
      if let document = input.document {
        pageSizes = try document.pdfiumSession.assemble(
          data: source,
          operation: operationValue,
          pageIndex: command.isAppend ? 0 : UInt(input.activePageIndex),
          destinationIndex: UInt(destination),
          appendInputs: appendInputs,
          scratchURL: allocated)
      } else {
        guard case .append = command else { throw InkSignView.MutablePageError.notReady }
        pageSizes = try InkSignPdfPdfiumSession.assembleNewPDF(
          appendInputs: appendInputs,
          scratchURL: allocated)
      }
      let loaded = try InkSignPdfDocumentCandidateLoader.load(
        url: allocated,
        fallbackFontPath: input.fallbackFont?.path,
        collectionIndex: input.fallbackFont?.collectionIndex ?? 0,
        expectedPageSizes: pageSizes.map(\.cgSizeValue))
      candidateSession = loaded.pdfiumSession
      switch command {
      case .append:
        guard loaded.pages.count > input.pages.count else {
          throw InkSignView.MutablePageError.assemblyFailed
        }
      case .remove:
        guard loaded.pages.count == input.pages.count - 1 else {
          throw InkSignView.MutablePageError.assemblyFailed
        }
      case .move:
        guard loaded.pages.count == input.pages.count else {
          throw InkSignView.MutablePageError.assemblyFailed
        }
      }

      let order: PageOrder
      if input.pages.isEmpty {
        guard case .append = command, let firstPage = loaded.pages.first else {
          throw InkSignView.MutablePageError.assemblyFailed
        }
        order = PageOrder(pages: loaded.pages, activePageID: firstPage.id,
                          addedPageCount: loaded.pages.count, changed: true)
      } else {
        switch command {
        case .append:
          let appended = Array(loaded.pages.dropFirst(input.pages.count))
          order = try Self.pageOrder(current: input.pages, activePageID: input.activePageID,
                                     mutation: .append(appended))
          guard order.addedPageCount > 0 else { throw InkSignView.MutablePageError.assemblyFailed }
        case .remove:
          order = try Self.pageOrder(current: input.pages, activePageID: input.activePageID,
                                     mutation: .removeActive)
        case .move(let target):
          order = try Self.pageOrder(current: input.pages, activePageID: input.activePageID,
                                     mutation: .moveActive(to: target))
        }
      }
      guard order.pages.count == loaded.pages.count else {
        throw InkSignView.MutablePageError.assemblyFailed
      }
      let reordered = order.pages.enumerated().map { index, record in
        InkSignPdfDocumentCandidateLoader.rebinding(record, to: loaded.pages[index])
      }
      guard reordered.count == pageSizes.count,
            reordered.allSatisfy({ $0.geometry.isValid }) else {
        throw InkSignView.MutablePageError.assemblyFailed
      }
      let candidate = InkSignPdfDocumentState(sourceURL: input.document?.sourceURL ?? allocated,
                                               workingURL: allocated,
                                               document: loaded.document,
                                               pdfiumSession: loaded.pdfiumSession,
                                               pages: reordered,
                                               activePageID: order.activePageID)
      candidateSession = nil
      return candidate
    } catch {
      candidateSession?.close()
      discardArtifact(allocated)
      artifactPolicy.deleteExact(allocated)
      throw error
    }
  }

  func discardCandidate(_ candidate: InkSignPdfDocumentState) {
    candidate.pdfiumSession.close()
    discardArtifact(candidate.workingURL)
    artifactPolicy.deleteExact(candidate.workingURL)
  }

  func releaseReplacedDocument(_ previous: InkSignPdfDocumentState) {
    previous.pdfiumSession.close()
    artifactPolicy.deleteExact(previous.workingURL)
  }

  func releaseStagedInputs(_ staged: [InkSignPdfStagedPageInput]) {
    staged.forEach { artifactPolicy.deleteExact($0.url) }
  }

}

private extension InkSignPdfDocumentCoordinator.StructuralCommand {
  var isAppend: Bool {
    if case .append = self { return true }
    return false
  }
}
