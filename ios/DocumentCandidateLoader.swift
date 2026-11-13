import Foundation

struct InkSignPdfDocumentCandidate {
  let pages: [InkSignPdfPageState]
}

enum InkSignPdfDocumentCandidateError: Error {
  case unreadable
  case empty
  case invalidGeometry
}

enum InkSignPdfDocumentCandidateLoader {
  static func load(url: URL,
                   retainingAnalysis: [Int: InkSignPdfPageAnalysis] = [:],
                   recordHistory: Bool = true, tag: String? = nil) throws -> InkSignPdfDocumentCandidate {
    let data = try Data(contentsOf: url)
    let metadata = try InkSignPdfPdfiumBackend.inspect(data: data)
    guard !metadata.isEmpty else { throw InkSignPdfDocumentCandidateError.empty }
    let missing = metadata.indices.filter { retainingAnalysis[$0] == nil }
    var analyses = retainingAnalysis
    if !missing.isEmpty {
      let snapshots = try InkSignPdfPdfiumBackend.analyze(data: data,
        pageIndices: missing.map { NSNumber(value: $0) })
      for snapshot in snapshots {
        analyses[snapshot.metadata.pageIndex] = InkSignPdfPageAnalysis.build(snapshot: snapshot)
      }
    }
    let pages = try metadata.enumerated().map { index, page -> InkSignPdfPageState in
      let geometry = PageGeometry(mediaBox: page.mediaBox, rotation: page.rotation, visibleBox: page.visibleBox)
      guard geometry.isValid else { throw InkSignPdfDocumentCandidateError.invalidGeometry }
      guard let analysis = analyses[index] else { throw InkSignPdfDocumentCandidateError.unreadable }
      return InkSignPdfPageState(tag: tag, geometry: geometry,
        history: InkSignPdfPageContentHistory(recordHistory: recordHistory), sourceAnalysis: analysis)
    }
    return InkSignPdfDocumentCandidate(pages: pages)
  }

  static func rebinding(_ oldPage: InkSignPdfPageState,
                        to candidatePage: InkSignPdfPageState) -> InkSignPdfPageState {
    InkSignPdfPageState(id: oldPage.id, tag: oldPage.tag, geometry: oldPage.geometry,
      history: oldPage.history, geometryRevision: oldPage.geometryRevision,
      sourceGeometry: candidatePage.sourceGeometry, sourceAnalysis: oldPage.sourceAnalysis,
      prepared: oldPage.prepared)
  }
}
