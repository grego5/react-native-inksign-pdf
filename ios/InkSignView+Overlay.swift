import Foundation
import PencilKit
import UIKit
import NitroModules
import QuartzCore

extension InkSignView {
  /// Gives an armed placement tap priority over every PDF navigation gesture
  /// that could otherwise observe the same touch sequence.
  func configureTextPlacementGestureRecognition() {
    let placement = textInteractionOverlay.placementTapRecognizer
    documentView.gestureRecognizers?.forEach { recognizer in
      guard recognizer !== placement else { return }
      recognizer.require(toFail: placement)
    }
  }

  /// Converts an overlay point into canonical media-box-relative page coordinates.
  func canonicalPagePoint(fromOverlay point: CGPoint) -> CGPoint? {
    guard let state = documentCoordinator.document,
          attachedOverlayPage == state.activePage.id,
          let transform = pageToOverlayTransform,
          let inverse = transform.invertedIfFinite else { return nil }
    let pagePoint = point.applying(inverse)
    let pageSize = state.activePage.geometry.mediaBox.size
    guard pagePoint.x.isFinite, pagePoint.y.isFinite,
          pagePoint.x >= 0, pagePoint.x <= pageSize.width,
          pagePoint.y >= 0, pagePoint.y <= pageSize.height else { return nil }
    return pagePoint
  }

  func isSupportedPage(_ pageID: UUID) -> Bool {
    guard let state = documentCoordinator.document else { return false }
    return state.activePage.id == pageID && state.activePage.geometry.isValid
  }

  func overlayDidDisplay(_ overlay: InkCanvasView, for pageID: UUID) {
    guard !disposed, overlay === canvasView, isSupportedPage(pageID) else { return }
    attachedOverlayPage = pageID
    refreshOverlayTransform(overlay, for: pageID)
    textInteractionOverlay.syncContent()
    if let pendingPageSwitchID { finishPageSwitchIfReady(requestID: pendingPageSwitchID) }
    _ = completeOpenIfReady()
  }

  func overlayDidEndDisplaying(_ overlay: InkCanvasView, for pageID: UUID) {
    guard overlay === canvasView, attachedOverlayPage == pageID else { return }
    attachedOverlayPage = nil
    textInteractionOverlay.finishForLifecycle()
    cancelActiveStroke()
    pageTurnLifecycle.overlayDetached()
    invalidateOverlayTransformCache()
  }

  func overlayLayoutChanged(_ overlay: InkCanvasView) {
    guard !disposed, let pageID = documentCoordinator.document?.activePage.id,
          attachedOverlayPage == pageID, isSupportedPage(pageID) else { return }
    refreshOverlayTransform(overlay, for: pageID)
    if let pendingPageSwitchID { finishPageSwitchIfReady(requestID: pendingPageSwitchID) }
    _ = completeOpenIfReady()
    pageTurnLifecycle.stableContextChanged()
  }

  /// Reports a completed gesture mutation. Presentation callbacks only refresh
  /// dependent state; they never issue another viewport mutation.
  func documentViewViewportChanged(_ view: InkPdfView) {
    guard view === documentView,
          let pageID = documentCoordinator.document?.activePage.id else { return }
    invalidateOverlayTransformCache()
    refreshOverlayTransform(canvasView, for: pageID)
  }

  func refreshOverlayTransform(_ overlay: InkCanvasView, for pageID: UUID) {
    guard isSupportedPage(pageID), attachedOverlayPage == pageID,
          let viewport = documentView.viewportTransform else {
      invalidateOverlayTransformCache()
      return
    }
    let documentOrigin = overlay.convert(CGPoint.zero, from: documentView)
    let documentXAxis = overlay.convert(CGPoint(x: 1, y: 0), from: documentView)
    let documentYAxis = overlay.convert(CGPoint(x: 0, y: 1), from: documentView)
    let documentToOverlay = CGAffineTransform(
      a: documentXAxis.x - documentOrigin.x,
      b: documentXAxis.y - documentOrigin.y,
      c: documentYAxis.x - documentOrigin.x,
      d: documentYAxis.y - documentOrigin.y,
      tx: documentOrigin.x,
      ty: documentOrigin.y)
    let transform = documentToOverlay.concatenating(viewport.canonicalToView)
    guard transform.a.isFinite, transform.b.isFinite,
          transform.c.isFinite, transform.d.isFinite,
          transform.tx.isFinite, transform.ty.isFinite,
          transform.invertedIfFinite != nil else {
      invalidateOverlayTransformCache()
      return
    }
    let mediaBox = viewport.geometry.mediaBox
    if overlayTransformPage == pageID,
       overlayTransformBounds == overlay.bounds,
       overlayTransformMediaBox == mediaBox,
       overlayTransformViewportFrame == viewport.pageFrame {
      return
    }
    if hasDrawingTransaction { cancelActiveStroke() }
    pageToOverlayTransform = transform
    overlayTransformPage = pageID
    overlayTransformBounds = overlay.bounds
    overlayTransformMediaBox = mediaBox
    overlayTransformViewportFrame = viewport.pageFrame
    installCommittedDrawing()
    textInteractionOverlay.syncTransform()
  }

  func invalidateOverlayTransformCache() {
    overlayTransformPage = nil
    overlayTransformBounds = .zero
    overlayTransformMediaBox = .zero
    overlayTransformViewportFrame = .zero
    pageToOverlayTransform = nil
  }
}
