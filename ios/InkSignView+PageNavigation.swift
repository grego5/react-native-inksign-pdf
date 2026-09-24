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
    guard let state = documentCoordinator.document else { return }
    let index = state.document.index(for: page)
    guard index >= 0, index < state.pages.count else { return }

    if index != state.activePageIndex {
      cancelPendingPageSwitch()
      textInteractionOverlay.finishForLifecycle()
      let wasEditing = editMode
      cancelActiveStroke()
      setInteractionMode(editing: false, interactionsEnabled: false)
      attachedOverlayPage = nil
      documentCoordinator.selectPage(id: state.pages[index].id)
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
    textInteractionOverlay.finishForLifecycle()
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

    pendingPageSwitchID = nil
    installCommittedDrawing()
    setInteractionMode(editing: pendingPageSwitchEditing)
    pendingPageSwitchEditing = false
    let completion = pendingPageSwitchCompletion
    pendingPageSwitchCompletion = nil
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
    completion?(.failure(ViewportError.cancelled))
  }
}
