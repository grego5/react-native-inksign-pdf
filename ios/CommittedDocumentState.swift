import Foundation

/// Published committed state. Page order determines indices; selection belongs to a viewer.
final class CommittedDocumentState {
  let sourceURL: URL
  let workingURL: URL
  private(set) var pages: [InkSignPdfPageState]

  init(sourceURL: URL, workingURL: URL, pages: [InkSignPdfPageState]) {
    precondition(!pages.isEmpty)
    self.sourceURL = sourceURL
    self.workingURL = workingURL
    self.pages = pages
  }

  func index(of pageID: UUID) -> Int? { pages.firstIndex { $0.id == pageID } }

  func replacePage(at index: Int, with page: InkSignPdfPageState) {
    pages[index] = page
  }
}

final class InkSignPdfPageState {
  let id: UUID
  let tag: String?
  let geometry: PageGeometry
  let history: InkSignPdfPageContentHistory
  let geometryRevision: UInt64
  let sourceGeometry: PageGeometry
  /// Canonical source analysis of the working page, retained across unchanged imports.
  let sourceAnalysis: InkSignPdfPageAnalysis
  let prepared: InkSignPdfPreparedPage

  var contentRevision: UInt64 { history.revision }

  init(id: UUID = UUID(), tag: String? = nil,
       geometry: PageGeometry,
       history: InkSignPdfPageContentHistory = InkSignPdfPageContentHistory(),
       geometryRevision: UInt64 = 0,
       sourceGeometry: PageGeometry? = nil,
       sourceAnalysis: InkSignPdfPageAnalysis,
       prepared: InkSignPdfPreparedPage? = nil) {
    self.id = id
    self.tag = tag
    self.geometry = geometry
    self.history = history
    self.geometryRevision = geometryRevision
    self.sourceGeometry = sourceGeometry ?? geometry
    self.sourceAnalysis = sourceAnalysis
    self.prepared = prepared ?? InkSignPdfPreparedPage(analysis: sourceAnalysis)
  }
}

struct InkSignPdfNativePageInfo {
  let pageIndex: Int
  let pageCount: Int
  let geometry: PageGeometry
}
