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
  static func load(url: URL,
                   retainingAnalysisFrom sourcePages: [InkSignPdfPageState]? = nil) throws -> InkSignPdfDocumentCandidate {
    guard let document = PDFDocument(url: url) else {
      throw InkSignPdfDocumentCandidateError.unreadable
    }
    guard document.pageCount > 0 else { throw InkSignPdfDocumentCandidateError.empty }
    if let sourcePages, sourcePages.count != document.pageCount {
      throw InkSignPdfDocumentCandidateError.unreadable
    }

    var pages: [InkSignPdfPageState] = []
    pages.reserveCapacity(document.pageCount)
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else {
        throw InkSignPdfDocumentCandidateError.unreadable
      }
      pages.append(try pageState(for: page, sourceAnalysis: sourcePages?[index].sourceAnalysis))
    }
    return InkSignPdfDocumentCandidate(document: document, pages: pages)
  }

  static func pageState(for page: PDFPage,
                        sourceAnalysis: InkSignPdfPageAnalysis? = nil) throws -> InkSignPdfPageState {
    let geometry = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)
    guard geometry.isValid else { throw InkSignPdfDocumentCandidateError.invalidGeometry }
    let analysis = sourceAnalysis ?? InkSignPdfPageAnalysis.build(page: page, mediaBox: geometry.mediaBox)
    return InkSignPdfPageState(page: page, geometry: geometry, sourceAnalysis: analysis)
  }

  static func rebinding(_ oldPage: InkSignPdfPageState,
                        to candidatePage: InkSignPdfPageState) -> InkSignPdfPageState {
    candidatePage.page.rotation = oldPage.geometry.rotation
    return InkSignPdfPageState(id: oldPage.id,
                        page: candidatePage.page,
                        geometry: oldPage.geometry,
                        history: oldPage.history,
                        geometryRevision: oldPage.geometryRevision,
                        sourceGeometry: candidatePage.sourceGeometry,
                        sourceAnalysis: oldPage.sourceAnalysis)
  }
}
