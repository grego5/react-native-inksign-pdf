import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules
import QuartzCore

extension PdfView {
  /// Gives an armed placement tap priority over every PDF navigation gesture
  /// that could otherwise observe the same touch sequence.
  func configureTextPlacementGestureRecognition() {
    let placement = textInteractionOverlay.placementTapRecognizer
    documentView.gestureRecognizers?.forEach { recognizer in
      guard recognizer !== placement else { return }
      recognizer.require(toFail: placement)
    }
  }

  /// Converts an overlay point through the coordinator-owned PDFKit mapping
  /// into canonical media-box-relative page coordinates.
  func canonicalPagePoint(fromOverlay point: CGPoint) -> CGPoint? {
    guard let state = documentState,
          attachedOverlayPage === state.activePage.page,
          let transform = pageToOverlayTransform,
          let inverse = transform.invertedIfFinite else { return nil }
    let pagePoint = point.applying(inverse)
    let pageSize = state.activePage.geometry.mediaBox.size
    guard pagePoint.x.isFinite, pagePoint.y.isFinite,
          pagePoint.x >= 0, pagePoint.x <= pageSize.width,
          pagePoint.y >= 0, pagePoint.y <= pageSize.height else { return nil }
    return pagePoint
  }

  func isSupportedPage(_ candidate: PDFPage) -> Bool {
    guard let state = documentState else { return false }
    return state.activePage.page === candidate && state.activePage.geometry.isValid
  }

  func overlayDidDisplay(_ overlay: InkCanvasView, for page: PDFPage) {
    guard !disposed, overlay === canvasView, isSupportedPage(page) else { return }
    attachedOverlayPage = page
    _ = tryApplyPendingOpenViewport()
    refreshOverlayTransform(overlay, for: page)
    textInteractionOverlay.syncContent()
    if let pendingPageSwitchID { finishPageSwitchIfReady(requestID: pendingPageSwitchID) }
    _ = tryCompletePendingOpen()
  }

  func overlayDidEndDisplaying(_ overlay: InkCanvasView, for page: PDFPage) {
    guard overlay === canvasView, attachedOverlayPage === page else { return }
    attachedOverlayPage = nil
    textInteractionOverlay.finishForLifecycle()
    cancelActiveStroke()
    pageTurnLifecycle.overlayDetached()
    invalidateOverlayTransformCache()
  }

  func overlayLayoutChanged(_ overlay: InkCanvasView) {
    guard !disposed, let page = documentState?.activePage.page,
          attachedOverlayPage === page, isSupportedPage(page) else { return }
    _ = tryApplyPendingOpenViewport()
    refreshOverlayTransform(overlay, for: page)
    if let pendingPageSwitchID { finishPageSwitchIfReady(requestID: pendingPageSwitchID) }
    _ = tryCompletePendingOpen()
    pageTurnLifecycle.stableContextChanged()
  }

  func documentViewLayoutChanged(_ view: InkPdfView) {
    guard view === documentView else { return }
    _ = tryApplyPendingOpenViewport()
    if let pendingPageSwitchID { finishPageSwitchIfReady(requestID: pendingPageSwitchID) }
    _ = tryCompletePendingOpen()
    pageTurnLifecycle.stableContextChanged()
  }

  func refreshOverlayTransform(_ overlay: InkCanvasView, for page: PDFPage) {
    guard isSupportedPage(page), attachedOverlayPage === page else { return }
    let mediaBox = documentState?.activePage.geometry.mediaBox ?? .zero
    if overlayTransformPage === page,
       overlayTransformBounds == overlay.bounds,
       overlayTransformMediaBox == mediaBox {
      return
    }
    func convert(_ point: CGPoint) -> CGPoint {
      let viewPoint = documentView.convert(point, from: page)
      return overlay.convert(viewPoint, from: documentView)
    }
    let origin = convert(CGPoint(x: mediaBox.minX, y: mediaBox.maxY))
    let xAxis = convert(CGPoint(x: mediaBox.maxX, y: mediaBox.maxY))
    let yAxis = convert(CGPoint(x: mediaBox.minX, y: mediaBox.minY))
    let transform = CGAffineTransform(
      a: (xAxis.x - origin.x) / mediaBox.width,
      b: (xAxis.y - origin.y) / mediaBox.width,
      c: (yAxis.x - origin.x) / mediaBox.height,
      d: (yAxis.y - origin.y) / mediaBox.height,
      tx: origin.x,
      ty: origin.y)
    let sx = sqrt(transform.a * transform.a + transform.b * transform.b)
    let sy = sqrt(transform.c * transform.c + transform.d * transform.d)
    let determinant = transform.a * transform.d - transform.b * transform.c
    let relativeDifference = abs(sx - sy) / max(sx, sy)
    guard transform.a.isFinite, transform.b.isFinite, transform.c.isFinite,
          transform.d.isFinite, transform.tx.isFinite, transform.ty.isFinite,
          sx.isFinite, sy.isFinite, sx > 0.0, sy > 0.0,
          determinant.isFinite, abs(determinant) > 0.000001,
          relativeDifference.isFinite, relativeDifference <= 0.001 else {
      return
    }
    if hasDrawingTransaction { cancelActiveStroke() }
    pageToOverlayTransform = transform
    overlayTransformPage = page
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
