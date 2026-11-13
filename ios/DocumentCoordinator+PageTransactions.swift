import Foundation
import NitroModules

extension InkSignPdfDocumentCoordinator {
  enum StructuralCommand {
    case append
    case remove
    case move(to: Int)
    case restore(CommittedDocumentState)
  }

  struct StructuralInput {
    let operation: OperationToken
    let document: CommittedDocumentState?
    let pages: [InkSignPdfPageState]
    let targetPageID: UUID
    let targetPageIndex: Int
    let imageGeometry: PageGeometry
    let imageTargetDpi: Double?
    let imageJpegQuality: Double?
    let recordHistory: Bool
    let tag: String?
  }

  func assembleCandidate(_ input: StructuralInput,
                         staged: [InkSignPdfStagedPageInput],
                         command: StructuralCommand,
                         sourceURL: URL? = nil) throws -> CommittedDocumentState {
    guard isCurrent(input.operation) else { throw MutablePageError.operationCancelled }
    let allocated = try artifactPolicy.allocateWorkingSource()
    guard registerPendingArtifact(allocated, for: input.operation) else {
      artifactPolicy.deleteExact(allocated)
      throw MutablePageError.operationCancelled
    }

    do {
      let source = try input.document.map { try Data(contentsOf: $0.workingURL) }
      var nativeInputs: [InkSignPdfPdfiumInput] = []
      var initialPDF: Data?
      let operation: InkSignPdfPdfiumAssemblyOperation
      let retained: [InkSignPdfPageState]
      var destination = 0
      switch command {
      case .append:
        operation = input.document == nil ? .create : .append
        retained = input.pages
        for stagedPage in staged {
          if stagedPage.type == .pdf {
            let bytes = try Data(contentsOf: stagedPage.url)
            nativeInputs.append(InkSignPdfPdfiumInput(pdfData: bytes))
            if input.document == nil && staged.count == 1 { initialPDF = bytes }
          } else {
            let image = try InkSignPdfImagePageEncoder.encode(
              stagedPage.url,
              geometry: input.imageGeometry,
              targetDpi: input.imageTargetDpi,
              jpegQuality: input.imageJpegQuality)
            nativeInputs.append(image.nativeInput)
          }
        }
      case .restore(let baseline):
        operation = .create
        retained = baseline.pages.map { page in
          let currentRevision = input.pages.first { $0.id == page.id }?.geometryRevision ?? 0
          return InkSignPdfPageState(id: page.id, tag: page.tag, geometry: page.geometry,
            history: page.history, geometryRevision: max(page.geometryRevision, currentRevision) &+ 1,
            sourceGeometry: page.sourceGeometry, sourceAnalysis: page.sourceAnalysis, prepared: page.prepared)
        }
        let bytes = try Data(contentsOf: baseline.workingURL)
        initialPDF = bytes
        nativeInputs = [InkSignPdfPdfiumInput(pdfData: bytes)]
      case .remove:
        operation = .remove
        let order = try Self.pageOrder(current: input.pages, activePageID: input.targetPageID,
                                        mutation: .removeActive)
        retained = order.pages
      case .move(let index):
        operation = .move
        destination = index
        retained = try Self.pageOrder(current: input.pages, activePageID: input.targetPageID,
                                        mutation: .moveActive(to: index)).pages
      }
      let metadata: [InkSignPdfPdfiumPageMetadata]
      if let initialPDF {
        try initialPDF.write(to: allocated, options: .atomic)
        metadata = try InkSignPdfPdfiumBackend.inspect(data: initialPDF)
      } else {
        metadata = try InkSignPdfPdfiumBackend.assemble(data: source, operation: operation,
          inputs: nativeInputs, pageIndex: input.targetPageIndex, destinationIndex: destination,
          outputURL: allocated)
      }
      let analysis = Dictionary(uniqueKeysWithValues: retained.enumerated().map { ($0.offset, $0.element.sourceAnalysis) })
      let reopened = try InkSignPdfDocumentCandidateLoader.load(url: allocated,
                                                               retainingAnalysis: analysis,
                                                               recordHistory: input.recordHistory, tag: input.tag)
      guard reopened.pages.count == metadata.count else {
        throw MutablePageError.assemblyFailed
      }
      for index in reopened.pages.indices {
        let actual = reopened.pages[index].geometry
        guard Self.sameRect(metadata[index].mediaBox, actual.mediaBox),
              Self.sameRect(metadata[index].visibleBox, actual.visibleBox),
              metadata[index].rotation == actual.rotation else {
          throw MutablePageError.assemblyFailed
        }
      }
      var pages = reopened.pages
      for index in retained.indices {
        pages[index] = InkSignPdfDocumentCandidateLoader.rebinding(retained[index], to: pages[index])
      }
      if case .append = command, pages.count <= input.pages.count {
        throw MutablePageError.assemblyFailed
      }
      let replacement = CommittedDocumentState(
        sourceURL: input.document?.sourceURL ?? sourceURL ?? allocated,
        workingURL: allocated,
        pages: pages)
      return replacement
    } catch {
      discardArtifact(allocated)
      artifactPolicy.deleteExact(allocated)
      throw error
    }
  }

  func discardCandidate(_ candidate: CommittedDocumentState) {
    discardArtifact(candidate.workingURL)
    artifactPolicy.deleteExact(candidate.workingURL)
  }

  func releaseStagedInputs(_ staged: [InkSignPdfStagedPageInput]) {
    staged.forEach { artifactPolicy.deleteExact($0.url) }
  }

  private static func sameRect(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.01 && abs(lhs.minY - rhs.minY) <= 0.01 &&
      abs(lhs.width - rhs.width) <= 0.01 && abs(lhs.height - rhs.height) <= 0.01
  }
}
