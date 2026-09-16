import Foundation
import PDFKit

/// Main-thread-owned document state. PDFView and the retained overlay are
/// presentation resources derived from this collection, not page owners.
final class InkSignPdfDocumentState {
  let sourceURL: URL
  let document: PDFDocument
  let pages: [InkSignPdfPageState]
  var activePageIndex: Int

  init(sourceURL: URL, document: PDFDocument, pages: [InkSignPdfPageState]) {
    precondition(!pages.isEmpty)
    self.sourceURL = sourceURL
    self.document = document
    self.pages = pages
    self.activePageIndex = 0
  }

  var activePage: InkSignPdfPageState {
    pages[activePageIndex]
  }
}

final class InkSignPdfPageState {
  let index: Int
  let page: PDFPage
  let geometry: PageGeometry
  let history = InkSignPdfPageContentHistory()

  var contentRevision: UInt64 { history.revision }

  init(index: Int, page: PDFPage, geometry: PageGeometry) {
    self.index = index
    self.page = page
    self.geometry = geometry
  }
}

struct InkSignPdfNativePageInfo {
  let pageIndex: Int
  let pageCount: Int
  let geometry: PageGeometry
}
