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

    let page = document.activePage
    let analysis = page.sourceAnalysis
    let geometry = page.geometry
    documentCoordinator.pdfQueue.async { [weak self] in
      let matches = analysis.labelCandidates.map(\.match)
      let displayed = analysis.displayedFieldGeometry(
        lookup: InkSignPdfTextLookup(hasLiteralMatch: !matches.isEmpty, matches: matches),
        geometry: geometry)
      DispatchQueue.main.async {
        guard let self, !self.disposed,
              self.documentCoordinator.generation == generation,
              let activePage = self.documentCoordinator.document?.activePage,
              activePage.id == pageID,
              self.documentCoordinator.document?.activePageIndex == pageIndex else { return }
        self.textInteractionOverlay.installPlacementRules(displayed.rules, labels: displayed.matches,
                                                          generation: generation,
                                                          pageID: pageID,
                                                          requestID: requestID)
      }
    }
  }
}
