import Foundation
import PDFKit

struct InkSignPdfDocumentCandidate {
  let document: PDFDocument
  let pdfiumSession: InkSignPdfPdfiumSession
  let pages: [InkSignPdfPageState]
}

enum InkSignPdfDocumentCandidateError: Error {
  case unreadable
  case empty
  case inconsistent
  case invalidPage
  case invalidGeometry
  case pdfium(Error)
}

enum InkSignPdfDocumentCandidateLoader {
  static func load(url: URL,
                   fallbackFontPath: String?,
                   collectionIndex: Double,
                   expectedPageSizes: [CGSize]? = nil) throws -> InkSignPdfDocumentCandidate {
    guard let document = PDFDocument(url: url) else { throw InkSignPdfDocumentCandidateError.unreadable }
    guard document.pageCount > 0 else { throw InkSignPdfDocumentCandidateError.empty }

    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let session: InkSignPdfPdfiumSession
    do {
      session = try InkSignPdfPdfiumSession(data: data,
                                            fallbackFontPath: fallbackFontPath,
                                            collectionIndex: collectionIndex)
    } catch {
      throw InkSignPdfDocumentCandidateError.pdfium(error)
    }
    var shouldCloseSession = true
    defer {
      if shouldCloseSession { session.close() }
    }

    guard session.pageCount == document.pageCount,
          expectedPageSizes == nil || expectedPageSizes?.count == document.pageCount else {
      throw InkSignPdfDocumentCandidateError.inconsistent
    }

    var pages: [InkSignPdfPageState] = []
    pages.reserveCapacity(document.pageCount)
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { throw InkSignPdfDocumentCandidateError.invalidPage }
      var pdfiumSize = CGSize.zero
      do {
        try session.pageSize(for: UInt(index), into: &pdfiumSize)
      } catch {
        throw InkSignPdfDocumentCandidateError.pdfium(error)
      }
      if let expectedPageSizes, !sizesMatch(pdfiumSize, expectedPageSizes[index]) {
        throw InkSignPdfDocumentCandidateError.inconsistent
      }

      let geometry = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)
      guard geometryMatches(geometry, pdfiumSize) else {
        throw InkSignPdfDocumentCandidateError.invalidGeometry
      }
      pages.append(InkSignPdfPageState(page: page, geometry: geometry))
    }

    shouldCloseSession = false
    return InkSignPdfDocumentCandidate(document: document, pdfiumSession: session, pages: pages)
  }

  static func rebinding(_ oldPage: InkSignPdfPageState,
                        to candidatePage: InkSignPdfPageState) -> InkSignPdfPageState {
    InkSignPdfPageState(id: oldPage.id,
                        page: candidatePage.page,
                        geometry: candidatePage.geometry,
                        history: oldPage.history)
  }

  private static func geometryMatches(_ geometry: PageGeometry, _ pdfiumSize: CGSize) -> Bool {
    guard pdfiumSize.width.isFinite, pdfiumSize.height.isFinite,
          pdfiumSize.width > 0, pdfiumSize.height > 0,
          geometry.isValid else { return false }
    let box = geometry.mediaBox
    let direct = dimensionsMatch(box.width, pdfiumSize.width) &&
      dimensionsMatch(box.height, pdfiumSize.height)
    let rotation = PageViewportTransform.normalizedRotation(geometry.rotation)
    let rotated = (rotation == 90 || rotation == 270) &&
      dimensionsMatch(box.width, pdfiumSize.height) &&
      dimensionsMatch(box.height, pdfiumSize.width)
    return direct || rotated
  }

  private static func sizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    dimensionsMatch(lhs.width, rhs.width) && dimensionsMatch(lhs.height, rhs.height)
  }

  private static func dimensionsMatch(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    abs(lhs - rhs) <= max(0.5, max(abs(lhs), abs(rhs)) * 0.001)
  }
}
