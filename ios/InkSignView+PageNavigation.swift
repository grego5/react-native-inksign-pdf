import Foundation
import PDFKit
import UIKit
import NitroModules

extension InkSignView {
  func documentViewPageDidChange() {
    guard let page = documentView.currentPage else { return }
    documentViewDidNavigate(to: page)
  }

  func documentViewDidNavigate(to page: PDFPage) {
    guard !suppressesOpenPresentationCallbacks,
          let state = viewerDocument else { return }
    let index = state.document.index(for: page)
    guard state.pages.indices.contains(index) else { return }
    if let request = interaction.presentation, request.structural,
       state.pages[index].id != request.pageID { return }
    if index != state.activePageIndex {
      let activePageID = state.activePage.id
      guard interaction.finishInteraction(), viewerDocument === state,
            state.activePage.id == activePageID else { return }
      attachedOverlayPage = nil
      viewerDocument?.selectPage(id: state.pages[index].id)
      let request = interaction.beginPresentation(page: state.activePage) { [weak self] result in
        if case .success = result { self?.emitPageState() }
      }
      guard interaction.presentation === request else { return }
      textInteractionOverlay.clearPlacementRules()
      invalidateOverlayTransformCache()
      textInteractionOverlay.syncContent()
    }
    guard let active = viewerDocument?.activePage,
          viewerDocument?.activePDFPage === page, overlayProvider.isDisplaying(page),
          let canvas = overlayProvider.canvasView(for: active.id) else { return }
    overlayDidDisplay(canvas, for: active.id)
  }

  @discardableResult
  func switchPage(to pageIndex: Int,
                  completion: ((Result<PageInfo, Error>) -> Void)? = nil) throws -> InkSignPdfNativePageInfo {
    guard let state = viewerDocument else { throw ViewportError.notReady }
    try interaction.viewport.requireViewportReady(request: .preserve)
    guard state.pages.indices.contains(pageIndex) else {
      throw ViewportError.invalidOptions("page index is out of range")
    }
    if pageIndex == state.activePageIndex { return try currentPageInfo() }
    let activePageID = state.activePage.id
    guard interaction.finishInteraction(), viewerDocument === state,
          state.activePage.id == activePageID else { throw ViewportError.cancelled }
    attachedOverlayPage = nil
    guard viewerDocument?.selectPage(id: state.pages[pageIndex].id) != nil else {
      throw ViewportError.notReady
    }
    let request = interaction.beginPresentation(page: state.activePage, completion: completion)
    guard interaction.presentation === request else { throw ViewportError.cancelled }
    textInteractionOverlay.clearPlacementRules()
    invalidateOverlayTransformCache()
    textInteractionOverlay.syncContent()
    interaction.viewport.navigate(to: state.activePDFPage)
    if documentView.currentPage === state.activePDFPage {
      documentViewDidNavigate(to: state.activePDFPage)
    }
    return try currentPageInfo()
  }

  func finishPagePresentationIfReady() {
    guard let request = interaction.presentation,
          let state = viewerDocument,
          documentCoordinator.generation == request.generation,
          state.activePage.id == request.pageID,
          state.activePage.geometryRevision == request.geometryRevision,
          interaction.viewport.viewportReadiness().allowsCommand(fitToPage: false) else { return }
    let target = request.viewport.flatMap { interaction.viewport.viewportTarget(for: $0) }
    if request.viewport != nil && target == nil { return }
    guard interaction.claimPresentation(request) else { return }
    if let target, !interaction.viewport.applyViewport(target: target) {
      if interaction.presentationIsCurrent(request) { interaction.resumePresentation(publish: false) }
      request.finish(.failure(ViewportError.notReady))
      if interaction.presentationIsCurrent(request) { emitChange() }
      return
    }
    guard interaction.presentationIsCurrent(request) else {
      request.finish(.failure(ViewportError.cancelled)); return
    }
    installCommittedDrawing()
    interaction.resumePresentation(publish: false)
    guard interaction.presentationIsCurrent(request) else {
      request.finish(.failure(ViewportError.cancelled)); return
    }
    do { request.finish(.success(toPublicPageInfo(try currentPageInfo()))) }
    catch { request.finish(.failure(error)) }
    if interaction.presentationIsCurrent(request) { emitChange() }
  }
}
