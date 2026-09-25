import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules

/// A command is ready when PDFKit has installed the active page and its overlay.
struct ViewportReadiness {
  let documentReady: Bool
  let viewInWindow: Bool
  let hasUsableBounds: Bool
  let activeOverlayAttached: Bool
  let fitScaleUsable: Bool

  func allowsCommand(fitToPage: Bool) -> Bool {
    documentReady && viewInWindow && hasUsableBounds && activeOverlayAttached &&
      (!fitToPage || fitScaleUsable)
  }
}

enum ViewportRequest {
  case preserve
  case fit
  case focus(CGPoint?, zoom: Double?)
}

struct ViewportTarget: Equatable {
  let zoom: CGFloat
  let focus: CGPoint
}

enum InkSignPdfTextViewportGeometry {
  static func panDelta(outline: CGRect,
                       caret: CGRect,
                       visibleBounds: CGRect,
                       margin: CGFloat = 24) -> CGPoint {
    let safeBounds = visibleBounds.insetBy(dx: margin, dy: margin)
    return CGPoint(x: axisDelta(min: outline.minX,
                                max: outline.maxX,
                                caretCenter: caret.midX,
                                safeMin: safeBounds.minX,
                                safeMax: safeBounds.maxX),
                   y: axisDelta(min: outline.minY,
                                max: outline.maxY,
                                caretCenter: caret.midY,
                                safeMin: safeBounds.minY,
                                safeMax: safeBounds.maxY))
  }

  private static func axisDelta(min: CGFloat,
                                max: CGFloat,
                                caretCenter: CGFloat,
                                safeMin: CGFloat,
                                safeMax: CGFloat) -> CGFloat {
    if max - min > safeMax - safeMin { return (safeMin + safeMax) / 2 - caretCenter }
    if min < safeMin { return safeMin - min }
    if max > safeMax { return safeMax - max }
    return 0
  }
}

extension InkSignView {
  @discardableResult
  func applyViewport(target: ViewportTarget) -> Bool {
    guard let state = documentCoordinator.document,
          documentView.currentPage === state.activePage.page else { return false }
    documentView.autoScales = false
    let zoom = min(max(target.zoom, documentView.minScaleFactor), documentView.maxScaleFactor)
    let mediaBox = state.activePage.geometry.mediaBox
    documentView.scaleFactor = zoom
    let destination = PDFDestination(
      page: state.activePage.page,
      at: CGPoint(x: mediaBox.minX + target.focus.x,
                  y: mediaBox.maxY - target.focus.y))
    destination.zoom = zoom
    documentView.go(to: destination)
    invalidateOverlayTransformCache()
    refreshOverlayTransform(canvasView, for: state.activePage.id)
    return true
  }

  func applyModeTransition(toEditing: Bool, request: ViewportRequest) throws {
    try requireViewportReady(request: request)
    cancelPendingPageSwitch()
    cancelActiveStroke()
    setInteractionMode(editing: toEditing)
    applyViewport(request: request)
  }

  func requireViewportReady(request: ViewportRequest) throws {
    let fitToPage: Bool
    if case .fit = request { fitToPage = true } else { fitToPage = false }
    guard viewportReadiness().allowsCommand(fitToPage: fitToPage) else {
      throw ViewportError.notReady
    }
  }

  func viewportReadiness() -> ViewportReadiness {
    let state = documentCoordinator.document
    return ViewportReadiness(
      documentReady: state?.activePage.geometry.isValid == true,
      viewInWindow: documentView.window != nil,
      hasUsableBounds: documentView.bounds.width > 0 && documentView.bounds.height > 0,
      activeOverlayAttached: state.map { attachedOverlayPage == $0.activePage.id } == true,
      fitScaleUsable: usableFitScale() != nil)
  }

  func programmaticPageSwitchCompletion() -> (Result<PageInfo, Error>) -> Void {
    { [weak self] result in
      switch result {
      case .success(let info):
        self?.onPageChange?(info)
      case .failure(let error):
        self?.reportPageNavigationFailure(error)
      }
    }
  }

  func reportPageNavigationFailure(_ error: Error) {
    if let viewportError = error as? ViewportError,
       case .cancelled = viewportError { return }
    print("ReactNativeInkSignPdf page navigation failed: \(error.localizedDescription)")
  }

  func usableFitScale() -> CGFloat? {
    guard documentView.bounds.width > 0, documentView.bounds.height > 0 else { return nil }
    let fitScale = documentView.scaleFactorForSizeToFit
    guard fitScale.isFinite, fitScale > 0 else { return nil }
    return min(max(fitScale, 0.1), 16)
  }

  @discardableResult
  func completeOpenIfReady() -> Bool {
    guard let pending = pendingOpen,
          pending.token == documentCoordinator.generation,
          !disposed,
          let state = documentCoordinator.document,
          state.activePageIndex == 0,
          documentView.currentPage === state.activePage.page,
          attachedOverlayPage == state.activePage.id,
          state.activePage.geometry.isValid,
          documentView.bounds.width > 0,
          documentView.bounds.height > 0 else {
      return false
    }
    if pending.fitToPage, usableFitScale() == nil { return false }
    guard let target = openViewportTarget(for: pending) else { return false }
    let operation = pending.operation
    do {
      guard applyViewport(target: target),
            attachedOverlayPage == state.activePage.id,
            overlayTransformPage == state.activePage.id,
            pageToOverlayTransform != nil else {
        throw ViewportError.notReady
      }
      pendingOpen = nil
      if let operation { documentCoordinator.settle(operation, succeeded: true) }
      setInteractionMode(editing: false)
      pending.promise.resolve(withResult: toPublicPageInfo(try currentPageInfo()))
      emitChange(force: true)
      return true
    } catch {
      let failed = pendingOpen
      pendingOpen = nil
      if let operation { documentCoordinator.settle(operation, succeeded: false) }
      restoreDocumentAfterOpenFailure(pending: failed)
      pending.promise.reject(withError: error)
      return false
    }
  }

  func restoreDocumentAfterOpenFailure(pending: PendingOpen? = nil) {
    guard let state = documentCoordinator.document else {
      documentView.document = nil
      overlayProvider.reset()
      setInteractionMode(editing: false, interactionsEnabled: false)
      return
    }
    overlayProvider.install(document: state.document,
                            generation: documentCoordinator.generation)
    documentView.document = state.document
    documentView.go(to: state.activePage.page)
    if let target = pending?.previousViewport {
      _ = applyViewport(target: target)
    }
    setInteractionMode(editing: pending?.previousEditing ?? false)
  }

  func currentViewportSnapshot() throws -> Viewport {
    try requireViewportReady(request: .preserve)
    guard let state = documentCoordinator.document,
          let page = documentView.currentPage,
          page === state.activePage.page else {
      throw ViewportError.notReady
    }
    let viewCenter = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let pdfFocus = documentView.convert(viewCenter, to: page)
    let mediaBox = state.activePage.geometry.mediaBox
    let x = min(max(pdfFocus.x - mediaBox.minX, 0), mediaBox.width)
    let y = min(max(mediaBox.maxY - pdfFocus.y, 0), mediaBox.height)
    let zoom = Double(documentView.scaleFactor)
    guard x.isFinite, y.isFinite, zoom.isFinite, zoom > 0 else {
      throw ViewportError.notReady
    }
    return Viewport(
      x: min(max(Double(x), 0), Double(mediaBox.width)),
      y: min(max(Double(y), 0), Double(mediaBox.height)),
      zoom: zoom,
    )
  }

  private func applyViewport(request: ViewportRequest) {
    guard let pageID = documentCoordinator.document?.activePage.id else { return }
    documentView.autoScales = false
    switch request {
    case .preserve:
      break
    case .fit:
      guard let target = viewportTarget(for: request) else { return }
      _ = applyViewport(target: target)
    case .focus:
      guard let target = viewportTarget(for: request) else { return }
      _ = applyViewport(target: target)
    }
    if case .preserve = request {
      invalidateOverlayTransformCache()
      refreshOverlayTransform(canvasView, for: pageID)
    }
  }

  private func viewportTarget(for request: ViewportRequest) -> ViewportTarget? {
    let pageGeometry = documentCoordinator.document?.activePage.geometry ?? .empty
    switch request {
    case .preserve:
      return nil
    case .fit:
      guard let zoom = usableFitScale() else { return nil }
      return ViewportTarget(
        zoom: zoom,
        focus: CGPoint(x: pageGeometry.mediaBox.width / 2,
                       y: pageGeometry.mediaBox.height / 2))
    case .focus(let focus, let zoom):
      let currentFocus = currentCanonicalFocus() ?? CGPoint(
        x: pageGeometry.mediaBox.width / 2,
        y: pageGeometry.mediaBox.height / 2
      )
      let targetZoom = CGFloat(zoom ?? Double(documentView.scaleFactor))
      return ViewportTarget(zoom: targetZoom, focus: focus ?? currentFocus)
    }
  }

  private func openViewportTarget(for pending: PendingOpen) -> ViewportTarget? {
    guard let state = documentCoordinator.document else { return nil }
    let mediaBox = state.activePage.geometry.mediaBox
    let focus = pending.focus ?? CGPoint(x: mediaBox.width / 2,
                                          y: mediaBox.height / 2)
    if pending.fitToPage {
      guard let zoom = usableFitScale() else { return nil }
      return ViewportTarget(
        zoom: zoom,
        focus: CGPoint(x: mediaBox.width / 2, y: mediaBox.height / 2))
    }
    return ViewportTarget(zoom: CGFloat(pending.zoom ?? 1), focus: focus)
  }

  func setTextKeyboardOcclusion(_ bottom: CGFloat) {
    textKeyboardOcclusion = bottom
  }

  func resetTextViewportAvoidance() {
    textKeyboardOcclusion = 0
  }

  /// Moves the PDF viewport by a screen-space delta while preserving zoom.
  /// Positive deltas follow the user's finger, so the page content moves in
  /// the same direction as the supplied translation.
  func panViewport(by translation: CGPoint) {
    guard !disposed,
          let state = documentCoordinator.document,
          let page = documentView.currentPage,
          page === state.activePage.page,
          documentView.bounds.width > 0,
          documentView.bounds.height > 0,
          translation.x.isFinite,
          translation.y.isFinite else { return }
    cancelActiveStroke()
    let center = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let pdfFocus = documentView.convert(CGPoint(x: center.x - translation.x,
                                                y: center.y - translation.y),
                                        to: page)
    let destination = PDFDestination(page: page, at: pdfFocus)
    destination.zoom = documentView.scaleFactor
    documentView.go(to: destination)
  }

  func ensureTextVisible(outline: CGRect, caret: CGRect) {
    let visible = container.bounds.inset(by: UIEdgeInsets(
      top: 0, left: 0, bottom: textKeyboardOcclusion, right: 0))
    let delta = InkSignPdfTextViewportGeometry.panDelta(outline: outline,
                                                       caret: caret,
                                                       visibleBounds: visible)
    guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }
    panViewport(by: delta)
  }

  @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
    guard !disposed, !editMode,
          documentCoordinator.document != nil else { return }
    if !isFittedToPage() {
      applyViewport(request: .fit)
      return
    }
    let targetZoom = doubleTap?.zoom ?? 2.0
    guard targetZoom.isFinite, targetZoom > 0 else { return }
    let clampedTargetZoom = CGFloat(min(max(targetZoom, 0.1), 16))
    let currentZoom = documentView.scaleFactor
    guard currentZoom.isFinite, clampedTargetZoom > currentZoom else { return }

    let location = recognizer.location(in: documentView)
    guard let page = documentView.currentPage else { return }
    let pdfPoint = documentView.convert(location, to: page)
    let mediaBox = documentCoordinator.document?.activePage.geometry.mediaBox ?? .zero
    let tappedPoint = CGPoint(x: pdfPoint.x - mediaBox.minX,
                              y: mediaBox.maxY - pdfPoint.y)
    guard tappedPoint.x.isFinite, tappedPoint.y.isFinite else { return }
    let focus = tappedPoint

    let entersEditMode = doubleTap?.enterEditMode == true
    guard applyViewport(target: ViewportTarget(zoom: clampedTargetZoom, focus: focus)) else { return }
    if entersEditMode { setInteractionMode(editing: true) }
  }

  func isFittedToPage() -> Bool {
    guard let pageGeometry = documentCoordinator.document?.activePage.geometry,
          pageGeometry.isValid,
          documentView.bounds.width > 0, documentView.bounds.height > 0,
          let fitScale = usableFitScale(),
          documentView.scaleFactor.isFinite else { return false }

    let viewPrecision = max(0.5, 1.0 / max(UIScreen.main.scale, 1.0))
    let pageExtent = max(pageGeometry.mediaBox.width, pageGeometry.mediaBox.height)
    let scaleTolerance = viewPrecision / pageExtent
    guard scaleTolerance.isFinite,
          abs(documentView.scaleFactor - fitScale) <= scaleTolerance else {
      return false
    }

    guard let page = documentView.currentPage,
          page === documentCoordinator.document?.activePage.page else { return false }
    let pageCenter = CGPoint(x: pageGeometry.mediaBox.midX, y: pageGeometry.mediaBox.midY)
    let pageCenterInView = documentView.convert(pageCenter, from: page)
    let viewCenter = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let centerDistance = hypot(pageCenterInView.x - viewCenter.x,
                               pageCenterInView.y - viewCenter.y)
    return pageCenterInView.x.isFinite && pageCenterInView.y.isFinite &&
      centerDistance.isFinite && centerDistance <= viewPrecision
  }

  func configureDoubleTapGestureRecognition() {
    documentView.gestureRecognizers?.forEach { recognizer in
      guard let tap = recognizer as? UITapGestureRecognizer,
            tap !== doubleTapGestureRecognizer,
            tap.numberOfTapsRequired >= 2 else { return }
      tap.require(toFail: doubleTapGestureRecognizer)
    }
  }

  private func currentCanonicalFocus() -> CGPoint? {
    guard let state = documentCoordinator.document,
          let page = documentView.currentPage,
          page === state.activePage.page else { return nil }
    let viewCenter = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let pdfPoint = documentView.convert(viewCenter, to: page)
    return CGPoint(x: pdfPoint.x - state.activePage.geometry.mediaBox.minX,
                   y: state.activePage.geometry.mediaBox.maxY - pdfPoint.y)
  }

  static func parseViewport(_ options: ViewportOptions?) -> ViewportRequest {
    guard let options else { return .preserve }
    guard options.x != nil || options.y != nil || options.zoom != nil else { return .fit }
    let focus = options.x.flatMap { x in
      options.y.map { y in CGPoint(x: x, y: y) }
    }
    return .focus(focus, zoom: options.zoom)
  }

  static func parseOpenViewport(_ options: ViewportOptions?) -> (zoom: Double?, focus: CGPoint?, fitToPage: Bool) {
    guard let options else { return (nil, nil, true) }
    let focus = options.x.flatMap { x in
      options.y.map { y in CGPoint(x: x, y: y) }
    }
    if options.x == nil && options.y == nil && options.zoom == nil {
      return (nil, nil, true)
    }
    return (options.zoom, focus, false)
  }

}
