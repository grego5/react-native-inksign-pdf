import Foundation
import PDFKit

struct InkSignPdfDocumentCandidate {
  let document: PDFDocument
  let pages: [InkSignPdfPageState]
}

enum InkSignPdfDocumentCandidateError: Error {
  case unreadable
  case empty
  case invalidGeometry
}

enum InkSignPdfDocumentCandidateLoader {
  static func load(url: URL) throws -> InkSignPdfDocumentCandidate {
    guard let document = PDFDocument(url: url) else {
      throw InkSignPdfDocumentCandidateError.unreadable
    }
    guard document.pageCount > 0 else { throw InkSignPdfDocumentCandidateError.empty }

    var pages: [InkSignPdfPageState] = []
    pages.reserveCapacity(document.pageCount)
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else {
        throw InkSignPdfDocumentCandidateError.unreadable
      }
      let geometry = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)
      guard geometry.isValid else { throw InkSignPdfDocumentCandidateError.invalidGeometry }
      pages.append(InkSignPdfPageState(page: page, geometry: geometry))
    }
    return InkSignPdfDocumentCandidate(document: document, pages: pages)
  }

  static func rebinding(_ oldPage: InkSignPdfPageState,
                        to candidatePage: InkSignPdfPageState) -> InkSignPdfPageState {
    InkSignPdfPageState(id: oldPage.id,
                        page: candidatePage.page,
                        geometry: candidatePage.geometry,
                        history: oldPage.history)
  }
}
