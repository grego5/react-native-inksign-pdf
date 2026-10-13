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
                   retainingAnalysis: [Int: InkSignPdfPageAnalysis] = [:]) throws -> InkSignPdfDocumentCandidate {
    guard let document = PDFDocument(url: url) else {
      throw InkSignPdfDocumentCandidateError.unreadable
    }
    guard document.pageCount > 0 else { throw InkSignPdfDocumentCandidateError.empty }
    let missing = (0..<document.pageCount).filter { retainingAnalysis[$0] == nil }
    var analyses = retainingAnalysis
    if !missing.isEmpty {
      let data = try Data(contentsOf: url)
      let snapshots = try InkSignPdfPdfiumBackend.analyze(data: data,
        pageIndices: missing.map { NSNumber(value: $0) })
      for snapshot in snapshots {
        analyses[snapshot.metadata.pageIndex] = InkSignPdfPageAnalysis.build(snapshot: snapshot)
      }
    }

    var pages: [InkSignPdfPageState] = []
    pages.reserveCapacity(document.pageCount)
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else {
        throw InkSignPdfDocumentCandidateError.unreadable
      }
      guard let analysis = analyses[index] else { throw InkSignPdfDocumentCandidateError.unreadable }
      pages.append(try pageState(for: page, sourceAnalysis: analysis))
    }
    return InkSignPdfDocumentCandidate(document: document, pages: pages)
  }

  static func pageState(for page: PDFPage,
                        sourceAnalysis: InkSignPdfPageAnalysis) throws -> InkSignPdfPageState {
    let geometry = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)
    guard geometry.isValid else { throw InkSignPdfDocumentCandidateError.invalidGeometry }
    return InkSignPdfPageState(page: page, geometry: geometry, sourceAnalysis: sourceAnalysis)
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
