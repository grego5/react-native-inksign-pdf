import CoreGraphics
import Foundation
import PDFKit
import NitroModules
import UIKit

extension ViewerCanvas {
  func installStructuralPresentation(_ state: CommittedDocumentState,
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
    // PDFKit's page controller keeps a stale page view when it receives a document
    // before layout, so installation waits for a sized view in a window.
    guard canInstallPresentation else {
      presentationInstallDeferred = true
      // The retiring state's working-file lease ends with this call; PDFKit must not keep
      // reading its document while the replacement waits for layout.
      if let shown = documentView.document, shown !== presented.document { detachShownDocument() }
      return
    }
    installPresentedDocument()
  }

  private func detachShownDocument() {
    documentView.document = nil
    overlayProvider.reset()
  }

  /// PDFKit sizes its page controller from `documentView`, whose constrained frame lags the
  /// container until the container's layout pass runs.
  var canInstallPresentation: Bool {
    documentView.window != nil && documentView.bounds.width > 0 && documentView.bounds.height > 0
  }

  func containerDidLayout() {
    guard !disposed, presentationInstallDeferred, canInstallPresentation else { return }
    presentationInstallDeferred = false
    guard viewerDocument != nil, interaction.presentation != nil else { return }
    installPresentedDocument()
  }

  private func installPresentedDocument() {
    guard let presented = viewerDocument else { return }
    invalidateOverlayTransformCache()
    textInteractionOverlay.clearPlacementRules()
    if documentView.document !== presented.document {
      documentView.document = nil
      overlayProvider.install(document: presented.document, generation: documentCoordinator.generation)
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

  /// Publishes a structural presentation result for the current core. A superseded request stays
  /// silent because its replacement publishes the state.
  func structuralPresentationCompletion() -> (Result<PageInfo, Error>) -> Void {
    let expectedCore = documentCore
    return { [weak self] result in
      guard let self, !self.disposed, self.document != nil, self.documentCore === expectedCore else { return }
      if case .failure(let error) = result {
        guard !Self.isSuperseded(error) else { return }
        self.loadError = error.localizedDescription
      }
      self.emitChange(force: true)
    }
  }
}
