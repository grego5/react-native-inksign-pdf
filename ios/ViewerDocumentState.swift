import Foundation
import PDFKit

/// Presentation lease and selection. Committed content stays in `core`.
final class InkSignPdfViewerDocument {
  let core: InkSignPdfDocumentState
  let document: PDFDocument
  private let workingLease: InkSignPdfWorkingLease
  private(set) var activePageID: UUID

  init(core: InkSignPdfDocumentState, coordinator: InkSignPdfDocumentCoordinator,
       activePageID: UUID? = nil) throws {
    let lease = coordinator.workingArtifacts.retain(core.workingURL)
    guard let document = PDFDocument(url: core.workingURL), document.pageCount == core.pages.count else {
      throw InkSignPdfLoadError.failed
    }
    self.core = core
    self.document = document
    workingLease = lease
    self.activePageID = activePageID.flatMap { core.index(of: $0) == nil ? nil : $0 } ?? core.pages[0].id
    for (index, page) in core.pages.enumerated() { document.page(at: index)?.rotation = page.geometry.rotation }
  }

  var pages: [InkSignPdfPageState] { core.pages }
  var workingURL: URL { core.workingURL }
  var sourceURL: URL { core.sourceURL }
  var activePageIndex: Int { core.index(of: activePageID)! }
  var activePage: InkSignPdfPageState { pages[activePageIndex] }
  var activePDFPage: PDFPage { document.page(at: activePageIndex)! }
  func index(of pageID: UUID) -> Int? { core.index(of: pageID) }
  func pdfPage(for pageID: UUID) -> PDFPage? { core.index(of: pageID).flatMap { document.page(at: $0) } }
  func selectPage(at index: Int) -> Bool {
    guard pages.indices.contains(index) else { return false }
    activePageID = pages[index].id
    return true
  }
  func selectPage(id: UUID) -> Int? {
    guard let index = core.index(of: id) else { return nil }
    activePageID = id
    return index
  }
}
