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

    var importedDocuments: [PDFDocument] = []
    do {
      let candidate: PDFDocument
      if let document = input.document {
        guard let detached = PDFDocument(url: document.workingURL) else {
          throw InkSignView.MutablePageError.assemblyFailed
        }
        candidate = detached
      } else {
        candidate = PDFDocument()
      }

      let order: PageOrder
      switch command {
      case .append:
        var appendedRecords: [InkSignPdfPageState] = []
        for stagedPage in staged {
          if stagedPage.type == .pdf {
            guard let source = PDFDocument(url: stagedPage.url), source.pageCount > 0 else {
              throw InkSignView.MutablePageError.assemblyFailed
            }
            importedDocuments.append(source)
            for sourceIndex in 0..<source.pageCount {
              guard let page = source.page(at: sourceIndex) else {
                throw InkSignView.MutablePageError.assemblyFailed
              }
              candidate.insert(page, at: candidate.pageCount)
            }
          } else {
            let page = try InkSignPdfMutablePageImageEncoder.encode(
              stagedPage.url, geometry: input.imageGeometry)
            candidate.insert(page, at: candidate.pageCount)
          }
        }

        guard candidate.pageCount > input.pages.count else {
          throw InkSignView.MutablePageError.assemblyFailed
        }
        let appended = try (input.pages.count..<candidate.pageCount).map { index in
          try Self.pageRecord(in: candidate, at: index)
        }
        if input.pages.isEmpty {
          guard let first = appended.first else { throw InkSignView.MutablePageError.assemblyFailed }
          order = PageOrder(pages: appended,
                            activePageID: first.id,
                            addedPageCount: appended.count,
                            changed: true)
        } else {
          order = try Self.pageOrder(current: input.pages,
                                     activePageID: input.activePageID,
                                     mutation: .append(appended))
        }
      case .remove:
        candidate.removePage(at: input.activePageIndex)
        order = try Self.pageOrder(current: input.pages,
                                   activePageID: input.activePageID,
                                   mutation: .removeActive)

      case .move(let destination):
        guard let page = candidate.page(at: input.activePageIndex) else {
          throw InkSignView.MutablePageError.assemblyFailed
        }
        candidate.removePage(at: input.activePageIndex)
        candidate.insert(page, at: destination)
        order = try Self.pageOrder(current: input.pages,
                                   activePageID: input.activePageID,
                                   mutation: .moveActive(to: destination))
      }

      var wroteCandidate = false
      withExtendedLifetime(importedDocuments) {
        wroteCandidate = candidate.write(to: allocated)
      }
      guard candidate.pageCount == order.pages.count, wroteCandidate else {
        throw InkSignView.MutablePageError.assemblyFailed
      }

      let reopened = try InkSignPdfDocumentCandidateLoader.load(url: allocated)
      guard reopened.pages.count == order.pages.count else {
        throw InkSignView.MutablePageError.assemblyFailed
      }
      for index in reopened.pages.indices {
        guard let expectedPage = candidate.page(at: index),
              let actualPage = reopened.document.page(at: index),
              Self.samePageProperties(expectedPage, actualPage) else {
          throw InkSignView.MutablePageError.assemblyFailed
        }
      }

      let pages = order.pages.enumerated().map { index, record in
        InkSignPdfDocumentCandidateLoader.rebinding(record, to: reopened.pages[index])
      }
      let replacement = InkSignPdfDocumentState(
        sourceURL: input.document?.sourceURL ?? allocated,
        workingURL: allocated,
        document: reopened.document,
        pages: pages,
        activePageID: order.activePageID)
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

  private static func pageRecord(in document: PDFDocument,
                                 at index: Int) throws -> InkSignPdfPageState {
    guard let page = document.page(at: index) else {
      throw InkSignView.MutablePageError.assemblyFailed
    }
    let geometry = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)
    guard geometry.isValid else { throw InkSignView.MutablePageError.assemblyFailed }
    return InkSignPdfPageState(page: page, geometry: geometry)
  }

  private static func samePageProperties(_ lhs: PDFPage, _ rhs: PDFPage) -> Bool {
    guard PageViewportTransform.normalizedRotation(lhs.rotation) ==
            PageViewportTransform.normalizedRotation(rhs.rotation) else { return false }
    let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
    return boxes.allSatisfy { sameRect(lhs.bounds(for: $0), rhs.bounds(for: $0)) }
  }

  private static func sameRect(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.01 && abs(lhs.minY - rhs.minY) <= 0.01 &&
      abs(lhs.width - rhs.width) <= 0.01 && abs(lhs.height - rhs.height) <= 0.01
  }
}
