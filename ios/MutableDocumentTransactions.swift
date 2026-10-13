import Foundation
import NitroModules
import PDFKit

extension InkSignPdfDocumentCoordinator {
  enum StructuralCommand {
    case append(activePage: AddPagesActivePage)
    case remove
    case move(to: Int)
  }

  struct StructuralInput {
    let operation: OperationToken
    let document: InkSignPdfDocumentState?
    let pages: [InkSignPdfPageState]
    let activePageID: UUID
    let activePageIndex: Int
    let imageGeometry: PageGeometry
    let imageTargetDpi: Double?
    let imageJpegQuality: Double?
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

    do {
      let source = try input.document.map { try Data(contentsOf: $0.workingURL) }
      var nativeInputs: [InkSignPdfPdfiumInput] = []
      let operation: InkSignPdfPdfiumAssemblyOperation
      let retained: [InkSignPdfPageState]
      var destination = 0
      var selectedID = input.activePageID
      switch command {
      case .append:
        operation = input.document == nil ? .create : .append
        retained = input.pages
        for stagedPage in staged {
          if stagedPage.type == .pdf {
            nativeInputs.append(InkSignPdfPdfiumInput(pdfData: try Data(contentsOf: stagedPage.url)))
          } else {
            let image = try InkSignPdfMutablePageImageEncoder.encode(
              stagedPage.url,
              geometry: input.imageGeometry,
              targetDpi: input.imageTargetDpi,
              jpegQuality: input.imageJpegQuality)
            nativeInputs.append(image.nativeInput)
          }
        }
      case .remove:
        operation = .remove
        let order = try Self.pageOrder(current: input.pages, activePageID: input.activePageID,
                                        mutation: .removeActive)
        retained = order.pages
        selectedID = order.activePageID
      case .move(let index):
        operation = .move
        destination = index
        retained = try Self.pageOrder(current: input.pages, activePageID: input.activePageID,
                                        mutation: .moveActive(to: index)).pages
      }
      let metadata = try InkSignPdfPdfiumBackend.assemble(data: source, operation: operation,
        inputs: nativeInputs, pageIndex: input.activePageIndex, destinationIndex: destination,
        outputURL: allocated)
      let analysis = Dictionary(uniqueKeysWithValues: retained.enumerated().map { ($0.offset, $0.element.sourceAnalysis) })
      let reopened = try InkSignPdfDocumentCandidateLoader.load(url: allocated,
                                                               retainingAnalysis: analysis)
      guard reopened.pages.count == metadata.count else {
        throw InkSignView.MutablePageError.assemblyFailed
      }
      for index in reopened.pages.indices {
        let actual = reopened.pages[index].geometry
        guard Self.sameRect(metadata[index].mediaBox, actual.mediaBox),
              metadata[index].rotation == actual.rotation else {
          throw InkSignView.MutablePageError.assemblyFailed
        }
      }
      var pages = reopened.pages
      for index in retained.indices {
        pages[index] = InkSignPdfDocumentCandidateLoader.rebinding(retained[index], to: pages[index])
      }
      if case .append(let activePage) = command {
        guard pages.count > input.pages.count else { throw InkSignView.MutablePageError.assemblyFailed }
        switch activePage {
        case .current: selectedID = input.pages.isEmpty ? pages[0].id : input.activePageID
        case .firstadded: selectedID = pages[input.pages.count].id
        case .lastadded: selectedID = pages[pages.count - 1].id
        }
      }
      let replacement = InkSignPdfDocumentState(
        sourceURL: input.document?.sourceURL ?? allocated,
        workingURL: allocated,
        document: reopened.document,
        pages: pages,
        activePageID: selectedID)
      return replacement
    } catch {
      discardArtifact(allocated)
      artifactPolicy.deleteExact(allocated)
      throw error
    }
  }

  func discardCandidate(_ candidate: InkSignPdfDocumentState) {
    discardArtifact(candidate.workingURL)
    artifactPolicy.deleteExact(candidate.workingURL)
  }

  func releaseReplacedDocument(_ previous: InkSignPdfDocumentState) {
    artifactPolicy.deleteExact(previous.workingURL)
  }

  func releaseStagedInputs(_ staged: [InkSignPdfStagedPageInput]) {
    staged.forEach { artifactPolicy.deleteExact($0.url) }
  }

  private static func sameRect(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.01 && abs(lhs.minY - rhs.minY) <= 0.01 &&
      abs(lhs.width - rhs.width) <= 0.01 && abs(lhs.height - rhs.height) <= 0.01
  }
}
