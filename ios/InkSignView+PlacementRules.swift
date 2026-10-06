import CoreGraphics
import Foundation

extension InkSignView {
  func schedulePlacementRuleScan(generation: UInt64,
                                 pageIndex: Int,
                                 pageID: UUID,
                                 requestID: UInt64) {
    guard let document = documentCoordinator.document else {
      preconditionFailure("Placement scan requires a published document")
    }
    precondition(documentCoordinator.generation == generation &&
                   document.activePageIndex == pageIndex &&
                   document.activePage.id == pageID,
                 "Placement scan must start for the active page")

    let source = document.workingURL
    let page = document.activePage
    let mediaBox = page.geometry.mediaBox
    let geometry = page.geometry
    documentCoordinator.pdfQueue.async { [weak self] in
      let analysis = self?.documentCoordinator.pageAnalysis(sourceURL: source,
        generation: generation, pageIndex: pageIndex, pageID: pageID, mediaBox: mediaBox)
      let rules: [InkSignPdfPlacementRule]
      let labels: [InkSignPdfKeyTextMatch]
      if let analysis {
        let matches = analysis.labelCandidates.map(\.match)
        let displayed = analysis.displayedFieldGeometry(
          lookup: InkSignPdfTextLookup(hasLiteralMatch: !matches.isEmpty, matches: matches),
          geometry: geometry)
        rules = displayed.rules
        labels = displayed.matches
      } else {
        rules = []
        labels = []
      }
      DispatchQueue.main.async {
        guard let self, !self.disposed,
              self.documentCoordinator.generation == generation,
              let activePage = self.documentCoordinator.document?.activePage,
              activePage.id == pageID,
              self.documentCoordinator.document?.activePageIndex == pageIndex else { return }
        self.textInteractionOverlay.installPlacementRules(rules, labels: labels,
                                                          generation: generation,
                                                          pageID: pageID,
                                                          requestID: requestID)
      }
    }
  }
}
