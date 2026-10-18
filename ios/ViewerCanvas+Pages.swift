import CoreGraphics
import Foundation
import PDFKit
import NitroModules
import UIKit

extension ViewerCanvas {
  func installStructuralPresentation(_ state: CommittedDocumentState,
                                             generation: UInt64,
                                             viewport: Viewport?,
                                             selectedPageID: UUID? = nil,
                                             fitPage: Bool = false,
                                             completion: @escaping (Result<PageInfo, Error>) -> Void) {

    let selected = selectedPageID ?? viewerDocument?.activePageID
    let presented: InkSignPdfViewerDocumentState
    do { presented = try InkSignPdfViewerDocumentState(core: state, coordinator: documentCoordinator, activePageID: selected) }
    catch { completion(.failure(error)); return }
    let retiring = viewerDocument
    defer { withExtendedLifetime(retiring) {} }
    viewerDocument = presented
    let page = presented.activePage
    let viewportRequest: ViewportRequest? = fitPage ? .fit : viewport.map {
      .focus(CGPoint(x: $0.x, y: $0.y), zoom: $0.zoom)
    }
    let request = interaction.beginPresentation(page: page, viewport: viewportRequest,
      structural: true, completion: completion)
    guard interaction.presentation === request else { return }
    invalidateOverlayTransformCache()
    textInteractionOverlay.clearPlacementRules()
    if documentView.document !== presented.document {
      documentView.document = nil
      overlayProvider.install(document: presented.document, generation: generation)
      documentView.document = presented.document
    }
    interaction.viewport.navigate(to: presented.activePDFPage)
    configureDoubleTapGestureRecognition()
    documentViewDidNavigate(to: presented.activePDFPage)
    documentView.layoutDocumentView()
    documentView.layoutIfNeeded()
    refreshActiveOverlayTransform()
    finishPagePresentationIfReady()
  }

}
