import CoreGraphics
import Foundation

extension InkSignView {
  func schedulePlacementRuleScan(generation: UInt64,
                                 pageIndex: Int,
                                 pageID: UUID,
                                 requestID: UInt64) {
    guard let document = viewerDocument else {
      preconditionFailure("Placement scan requires a published document")
    }
    precondition(documentCoordinator.generation == generation &&
                   document.activePageIndex == pageIndex &&
                   document.activePage.id == pageID,
                 "Placement scan must start for the active page")

    let page = document.activePage
    let displayed = page.prepared.projected(geometry: page.geometry).geometry
    textInteractionOverlay.installPlacementRules(displayed.rules, labels: displayed.matches,
                                                 generation: generation, pageID: pageID,
                                                 requestID: requestID)
  }
}
