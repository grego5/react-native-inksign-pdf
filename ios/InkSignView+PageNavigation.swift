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
    guard !suppressesOpenPresentationCallbacks else { return }
    guard let state = documentCoordinator.document else { return }
    let index = state.document.index(for: page)
    guard index >= 0, index < state.pages.count else { return }
    if let target = pendingStructuralPresentationPageID, state.pages[index].id != target {
      return
    }

    if index != state.activePageIndex {
      cancelPendingPageSwitch()
      finishInteractionForLifecycle()
      let wasEditing = editMode
      cancelActiveStroke()
      setInteractionMode(editing: false, interactionsEnabled: false)
      attachedOverlayPage = nil
      documentCoordinator.selectPage(id: state.pages[index].id)
      textInteractionOverlay.clearPlacementRules()
      invalidateOverlayTransformCache()
      textInteractionOverlay.syncContent()
      pageSwitchRequestID &+= 1
      pendingPageSwitchID = pageSwitchRequestID
      pendingPageSwitchEditing = wasEditing
      pendingPageSwitchCompletion = { [weak self] result in
        if case .success(let info) = result { self?.onPageChange?(info) }
      }
    }

    guard let active = documentCoordinator.document?.activePage,
          active.page === page,
          overlayProvider.isDisplaying(page),
          let canvas = overlayProvider.canvasView(for: active.id) else { return }
    overlayDidDisplay(canvas, for: active.id)
  }

  @discardableResult
  func switchPage(
    to pageIndex: Int,
    completion: ((Result<PageInfo, Error>) -> Void)? = nil
  ) throws -> InkSignPdfNativePageInfo {
    guard let state = documentCoordinator.document else { throw ViewportError.notReady }
    try requireViewportReady(request: .preserve)
    guard state.pages.indices.contains(pageIndex) else {
      throw ViewportError.invalidOptions("page index is out of range")
    }
    if pageIndex == state.activePageIndex { return try currentPageInfo() }

    cancelPendingPageSwitch()
    finishInteractionForLifecycle()
    let wasEditing = editMode
    cancelActiveStroke()
    setInteractionMode(editing: false, interactionsEnabled: false)
    attachedOverlayPage = nil
    pendingPageSwitchEditing = wasEditing
    pendingPageSwitchCompletion = completion
    pageSwitchRequestID &+= 1
    pendingPageSwitchID = pageSwitchRequestID
    guard documentCoordinator.selectPage(id: state.pages[pageIndex].id) != nil else {
      cancelPendingPageSwitch()
      throw ViewportError.notReady
    }
    textInteractionOverlay.clearPlacementRules()
    invalidateOverlayTransformCache()
    textInteractionOverlay.syncContent()

    let page = state.pages[pageIndex].page
    documentView.go(to: page)
    if documentView.currentPage === page {
      documentViewDidNavigate(to: page)
    }
    return try currentPageInfo()
  }

  func finishPageSwitchIfReady(requestID: UInt64) {
    guard pendingPageSwitchID == requestID,
          let state = documentCoordinator.document,
          documentView.currentPage === state.activePage.page,
          attachedOverlayPage == state.activePage.id,
          overlayTransformPage == state.activePage.id,
          pageToOverlayTransform != nil else { return }

    let viewport = pendingPageSwitchViewport.flatMap { viewportTarget(for: $0) }
    if pendingPageSwitchViewport != nil && viewport == nil { return }
    pendingPageSwitchID = nil
    pendingPageSwitchViewport = nil
    let wasEditing = pendingPageSwitchEditing
    pendingPageSwitchEditing = false
    let completion = pendingPageSwitchCompletion
    pendingPageSwitchCompletion = nil
    let isStructural = structuralInteractionSuspended
    if let viewport, !applyViewport(target: viewport) {
      pendingStructuralPresentationPageID = nil
      if isStructural { resumeStructuralInteraction() }
      completion?(.failure(ViewportError.notReady))
      return
    }
    pendingStructuralPresentationPageID = nil
    installCommittedDrawing()
    if isStructural { resumeStructuralInteraction() }
    else { setInteractionMode(editing: wasEditing) }
    if let completion {
      do {
        completion(.success(toPublicPageInfo(try currentPageInfo())))
      } catch {
        completion(.failure(error))
      }
    }
  }

  func cancelPendingPageSwitch() {
    let completion = pendingPageSwitchCompletion
    pendingPageSwitchCompletion = nil
    pendingPageSwitchID = nil
    pendingPageSwitchEditing = false
    pendingPageSwitchViewport = nil
    pendingStructuralPresentationPageID = nil
    completion?(.failure(ViewportError.cancelled))
  }
}
