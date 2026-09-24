import Foundation
import PencilKit
import UIKit
import NitroModules
import QuartzCore

extension InkSignView {
  func overlayProviderWillReset() {
    textInteractionOverlay.finishForLifecycle()
    textInteractionOverlay.removeFromSuperview()
    cancelActiveStroke()
    attachedOverlayPage = nil
    invalidateOverlayTransformCache()
  }

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
    guard !disposed,
          overlayProvider.canvasView(for: pageID) === overlay,
          isSupportedPage(pageID) else { return }
    if textInteractionOverlay.superview !== overlay {
      textInteractionOverlay.removeFromSuperview()
      textInteractionOverlay.frame = overlay.bounds
      textInteractionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      overlay.addSubview(textInteractionOverlay)
    }
    attachedOverlayPage = pageID
    refreshOverlayTransform(overlay, for: pageID)
    textInteractionOverlay.syncContent()
    if let pendingPageSwitchID { finishPageSwitchIfReady(requestID: pendingPageSwitchID) }
    _ = completeOpenIfReady()
  }

  func overlayDidEndDisplaying(_ overlay: InkCanvasView, for pageID: UUID) {
    guard overlayProvider.canvasView(for: pageID) === overlay,
          attachedOverlayPage == pageID else { return }
    attachedOverlayPage = nil
    textInteractionOverlay.finishForLifecycle()
    cancelActiveStroke()
    invalidateOverlayTransformCache()
  }

  func overlayLayoutChanged(_ overlay: InkCanvasView) {
    guard !disposed, overlay === canvasView,
          let pageID = documentCoordinator.document?.activePage.id,
          attachedOverlayPage == pageID, isSupportedPage(pageID) else { return }
    refreshOverlayTransform(overlay, for: pageID)
    if let pendingPageSwitchID { finishPageSwitchIfReady(requestID: pendingPageSwitchID) }
    _ = completeOpenIfReady()
  }

  func refreshActiveOverlayTransform() {
    guard let state = documentCoordinator.document,
          let canvas = overlayProvider.canvasView(for: state.activePage.id) else { return }
    refreshOverlayTransform(canvas, for: state.activePage.id)
  }

  /// Reports a completed gesture mutation. Presentation callbacks only refresh
  /// dependent state; they never issue another viewport mutation.
  func refreshOverlayTransform(_ overlay: InkCanvasView, for pageID: UUID) {
    guard isSupportedPage(pageID), attachedOverlayPage == pageID,
          let state = documentCoordinator.document,
          let page = documentView.currentPage,
          page === state.activePage.page else {
      invalidateOverlayTransformCache()
      return
    }
    let mediaBox = state.activePage.geometry.mediaBox
    func overlayPoint(canonical: CGPoint) -> CGPoint {
      let pdfPoint = CGPoint(x: canonical.x + mediaBox.minX,
                             y: mediaBox.maxY - canonical.y)
      let viewPoint = documentView.convert(pdfPoint, from: page)
      return overlay.convert(viewPoint, from: documentView)
    }
    let origin = overlayPoint(canonical: .zero)
    let xAxis = overlayPoint(canonical: CGPoint(x: 1, y: 0))
    let yAxis = overlayPoint(canonical: CGPoint(x: 0, y: 1))
    let transform = CGAffineTransform(a: xAxis.x - origin.x,
                                      b: xAxis.y - origin.y,
                                      c: yAxis.x - origin.x,
                                      d: yAxis.y - origin.y,
                                      tx: origin.x,
                                      ty: origin.y)
    guard transform.a.isFinite, transform.b.isFinite,
          transform.c.isFinite, transform.d.isFinite,
          transform.tx.isFinite, transform.ty.isFinite,
          transform.invertedIfFinite != nil else {
      invalidateOverlayTransformCache()
      return
    }
    if overlayTransformPage == pageID,
       overlayTransformBounds == overlay.bounds,
       overlayTransformMediaBox == mediaBox {
      return
    }
    if hasDrawingTransaction { cancelActiveStroke() }
    pageToOverlayTransform = transform
    overlayTransformPage = pageID
    overlayTransformBounds = overlay.bounds
    overlayTransformMediaBox = mediaBox
    installCommittedDrawing()
    textInteractionOverlay.syncTransform()
  }

  func invalidateOverlayTransformCache() {
    overlayTransformPage = nil
    overlayTransformBounds = .zero
    overlayTransformMediaBox = .zero
    pageToOverlayTransform = nil
  }
}
