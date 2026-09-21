import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules
import QuartzCore

extension InkSignView {
  @discardableResult
  func switchPage(
    to pageIndex: Int,
    completion: ((Result<PageInfo, Error>) -> Void)? = nil
  ) throws -> InkSignPdfNativePageInfo {
    guard let state = documentState else { throw ViewportError.notReady }
    try requireViewportReady(request: .preserve)
    guard pageIndex >= 0, pageIndex < state.pages.count else {
      throw ViewportError.invalidOptions("page index is out of range")
    }
    if pageIndex == state.activePageIndex { return try currentPageInfo() }

    cancelPendingPageSwitch()
    textInteractionOverlay.finishForLifecycle()
    pendingPageSwitchCompletion = completion
    attachedOverlayPage = nil
    let wasEditing = editMode
    cancelViewportAnimation()
    cancelActiveStroke()
    pendingPageSwitchEditing = wasEditing
    setInteractionMode(editing: false, interactionsEnabled: false)
    pageSwitchRequestID &+= 1
    let requestID = pageSwitchRequestID
    pendingPageSwitchID = requestID
    state.activePageIndex = pageIndex
    invalidateOverlayTransformCache()
    textInteractionOverlay.syncContent()
    canvasView.isInstallingDrawing = true
    canvasView.drawing = PKDrawing()
    canvasView.isInstallingDrawing = false

    let target = state.activePage
    pageTurnLifecycle.pageSwitchStarted(switchID: requestID, targetPageIndex: pageIndex)
    documentView.installPage(index: target.index,
                             page: target.page,
                             geometry: target.geometry,
                             session: state.pdfiumSession,
                             generation: generation)
    overlayDidDisplay(canvasView, for: target.page)
    return try currentPageInfo()
  }

  @objc func handleEdgeNavigationPan(_ recognizer: UIPanGestureRecognizer) {
    switch recognizer.state {
    case .began, .changed:
      pageTurnLifecycle.pullChanged(translation: recognizer.translation(in: documentView))
    case .ended:
      pageTurnLifecycle.pullEnded()
    case .cancelled, .failed:
      pageTurnLifecycle.pullCancelled()
    default:
      break
    }
  }

  func beginPageTurnCommit(targetPageIndex: Int) {
    guard !disposed, documentState != nil else {
      pageTurnLifecycle.pageTurnCommitFailedBeforeStart()
      return
    }
    do {
      try switchPage(to: targetPageIndex) { [weak self] result in
        if case .success(let info) = result { self?.onPageChange?(info) }
      }
    } catch {
      pageTurnLifecycle.pageTurnCommitFailedBeforeStart()
      setInteractionMode(editing: false)
    }
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    if gestureRecognizer === edgeNavigationGestureRecognizer ||
        gestureRecognizer === doubleTapGestureRecognizer,
       let target = touch.view,
       target === textInteractionOverlay || target.isDescendant(of: textInteractionOverlay) {
      return false
    }
    guard gestureRecognizer === edgeNavigationGestureRecognizer else { return true }
    return prepareForEdgeNavigationTouch(at: touch.location(in: documentView))
  }

  @discardableResult
  func prepareForEdgeNavigationTouch(at location: CGPoint) -> Bool {
    pageTurnLifecycle.prepareForEdgeNavigationTouch(at: location)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    gestureRecognizer === edgeNavigationGestureRecognizer ||
      otherGestureRecognizer === edgeNavigationGestureRecognizer
  }

  func finishPageSwitchIfReady(requestID: UInt64) {
    guard pendingPageSwitchID == requestID,
          let state = documentState,
          documentView.currentPage === state.activePage.page,
          attachedOverlayPage === state.activePage.page,
          documentView.bounds.width > 0,
          documentView.bounds.height > 0,
          let fitScale = usableFitScale() else { return }
    guard applyViewport(target: ViewportTarget(
      zoom: fitScale,
      focus: CGPoint(x: state.activePage.geometry.mediaBox.width / 2,
                     y: state.activePage.geometry.mediaBox.height / 2))) else { return }
    guard pendingPageSwitchID == requestID,
          documentView.currentPage === state.activePage.page,
          documentView.scaleFactor.isFinite,
          documentView.scaleFactor >= 0.1,
          documentView.scaleFactor <= 16,
          attachedOverlayPage === state.activePage.page,
          overlayTransformPage === state.activePage.page,
          pageToOverlayTransform != nil,
          isFittedToPage() else { return }
    if case .committed = pageTurnLifecycle.phase {
      guard pageTurnLifecycle.pageSwitchReady(switchID: requestID) else { return }
    }
    pendingPageSwitchID = nil
    let completion = pendingPageSwitchCompletion
    pendingPageSwitchCompletion = nil
    installCommittedDrawing()
    setInteractionMode(editing: pendingPageSwitchEditing)
    pendingPageSwitchEditing = false
    if let completion {
      do {
        completion(.success(toPublicPageInfo(try currentPageInfo())))
      } catch {
        completion(.failure(error))
      }
    }
  }

  func cancelPendingPageSwitch() {
    let switchID = pendingPageSwitchID
    let completion = pendingPageSwitchCompletion
    pendingPageSwitchCompletion = nil
    pendingPageSwitchID = nil
    pendingPageSwitchEditing = false
    if let switchID {
      pageTurnLifecycle.pageSwitchCancelled(switchID: switchID)
    }
    completion?(.failure(ViewportError.cancelled))
  }


}
