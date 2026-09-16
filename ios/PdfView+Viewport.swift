import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules
import QuartzCore

/// Shared command/open readiness policy. Keeping this value independent of
/// PDFKit objects makes the production lifecycle predicate directly testable.
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

final class ViewportAnimationDriver: NSObject, InkSignPdfPageTurnAnimationDriver {
  private let duration: CFTimeInterval
  private let update: (CGFloat) -> Void
  private let finish: () -> Void
  private var displayLink: CADisplayLink?
  private let startTime = CACurrentMediaTime()

  init(duration: CFTimeInterval, update: @escaping (CGFloat) -> Void, finish: @escaping () -> Void) {
    self.duration = duration
    self.update = update
    self.finish = finish
  }

  func start() {
    let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
    self.displayLink = displayLink
    displayLink.add(to: .main, forMode: .common)
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc private func tick(_ displayLink: CADisplayLink) {
    let linearProgress = min(max((displayLink.timestamp - startTime) / duration, 0), 1)
    let easedProgress = 1 - pow(1 - linearProgress, 3)
    update(CGFloat(easedProgress))
    if linearProgress >= 1 {
      stop()
      finish()
    }
  }
}

extension PdfView {
  func applyViewport(zoom: Double?, focus: CGPoint?, fitToPage: Bool = false) {
    guard let page = documentState?.activePage.page else { return }
    let pageGeometry = documentState?.activePage.geometry ?? .empty
    documentView.layoutIfNeeded()
    documentView.minScaleFactor = 0.1
    documentView.maxScaleFactor = 16
    documentView.autoScales = false
    if fitToPage {
      guard let fitScale = usableFitScale() else { return }
      documentView.scaleFactor = fitScale
      documentView.go(to: destination(for: CGPoint(
        x: pageGeometry.mediaBox.width / 2,
        y: pageGeometry.mediaBox.height / 2
      ), page: page))
    } else {
      documentView.scaleFactor = CGFloat(min(max(zoom ?? 1, 0.1), 16))
      if let focus {
        documentView.go(to: destination(for: focus, page: page))
      }
    }
    documentView.layoutIfNeeded()
    invalidateOverlayTransformCache()
    refreshOverlayTransform(canvasView, for: page)
  }

  func applyModeTransition(toEditing: Bool, request: ViewportRequest) throws {
    try requireViewportReady(request: request)
    cancelPendingPageSwitch()
    pageTurnLifecycle.cancelUncommittedTurn()
    canvasView.isUserInteractionEnabled = false
    documentView.gestureRecognizers?.forEach { $0.isEnabled = false }
    cancelActiveStroke()
    applyViewport(request: request, animated: true)
    setInteractionMode(editing: toEditing)
  }

  func requireViewportReady(request: ViewportRequest) throws {
    let fitToPage: Bool
    if case .fit = request { fitToPage = true } else { fitToPage = false }
    guard viewportReadiness().allowsCommand(fitToPage: fitToPage) else {
      throw ViewportError.notReady
    }
  }

  func viewportReadiness() -> ViewportReadiness {
    let state = documentState
    return ViewportReadiness(
      documentReady: state?.activePage.geometry.isValid == true,
      viewInWindow: documentView.window != nil,
      hasUsableBounds: documentView.bounds.width > 0 && documentView.bounds.height > 0,
      activeOverlayAttached: state.map { attachedOverlayPage === $0.activePage.page } == true,
      fitScaleUsable: usableFitScale() != nil)
  }

  func programmaticPageSwitchCompletion(
    promise: Promise<PageInfo>
  ) -> (Result<PageInfo, Error>) -> Void {
    { [weak self] result in
      switch result {
      case .success(let info):
        self?.onPageChange?(info)
        promise.resolve(withResult: info)
      case .failure(let error):
        promise.reject(withError: error)
      }
    }
  }

  func usableFitScale() -> CGFloat? {
    guard documentView.bounds.width > 0, documentView.bounds.height > 0 else { return nil }
    let fitScale = documentView.scaleFactorForSizeToFit
    guard fitScale.isFinite, fitScale > 0 else { return nil }
    return min(max(fitScale, 0.1), 16)
  }

  @discardableResult
  func tryApplyPendingOpenViewport() -> Bool {
    guard let pending = pendingOpen,
          pending.token == generation,
          !disposed,
          documentState != nil,
          documentState?.activePage.geometry.isValid == true else {
      return false
    }
    guard usableFitScale() != nil else { return false }
    applyViewport(zoom: pending.zoom,
                  focus: pending.focus,
                  fitToPage: pending.fitToPage)
    return true
  }

  @discardableResult
  func tryCompletePendingOpen() -> Bool {
    guard let pending = pendingOpen,
          pending.token == generation,
          !disposed,
          let state = documentState,
          state.activePageIndex == 0,
          attachedOverlayPage === state.activePage.page else {
      return false
    }
    do {
      try requireViewportReady(request: pending.fitToPage ? .fit : .preserve)
    } catch {
      return false
    }
    guard tryApplyPendingOpenViewport(),
          pendingOpen?.token == pending.token,
          attachedOverlayPage === state.activePage.page,
          overlayTransformPage === state.activePage.page,
          pageToOverlayTransform != nil else {
      return false
    }
    setInteractionMode(editing: false)
    pendingOpen = nil
    do {
      pending.promise.resolve(withResult: toPublicPageInfo(try currentPageInfo()))
      emitChange(force: true)
      return true
    } catch {
      pending.promise.reject(withError: error)
      return false
    }
  }

  func currentViewportSnapshot() throws -> Viewport {
    try requireViewportReady(request: .preserve)
    guard let page = documentState?.activePage.page else { throw ViewportError.notReady }
    let viewCenter = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let pdfPoint = documentView.convert(viewCenter, to: page)
    let mediaBox = documentState?.activePage.geometry.mediaBox ?? .zero
    let x = pdfPoint.x - mediaBox.minX
    let y = mediaBox.maxY - pdfPoint.y
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

  private func applyViewport(request: ViewportRequest, animated: Bool = false) {
    guard let page = documentState?.activePage.page else { return }
    let pageGeometry = documentState?.activePage.geometry ?? .empty
    cancelViewportAnimation()
    documentView.layoutIfNeeded()
    documentView.minScaleFactor = 0.1
    documentView.maxScaleFactor = 16
    documentView.autoScales = false
    if animated, let target = viewportTarget(for: request) {
      let currentZoom = CGFloat(documentView.scaleFactor)
      let currentFocus = currentCanonicalFocus()
      if target.zoom != currentZoom || target.focus != currentFocus {
        animateViewport(to: target, page: page)
        return
      }
    }
    switch request {
    case .preserve:
      break
    case .fit:
      guard let fitScale = usableFitScale() else { return }
      documentView.scaleFactor = fitScale
      documentView.go(to: destination(for: CGPoint(x: pageGeometry.mediaBox.width / 2,
                                                    y: pageGeometry.mediaBox.height / 2),
                                        page: page))
    case .focus(let focus, let zoom):
      let preservedFocus = focus == nil ? currentCanonicalFocus() : nil
      if let zoom {
        documentView.scaleFactor = CGFloat(min(max(zoom, 0.1), 16))
      }
      if let focus {
        documentView.go(to: destination(for: focus, page: page))
      } else if let preservedFocus {
        documentView.go(to: destination(for: preservedFocus, page: page))
      }
    }
    documentView.layoutIfNeeded()
    invalidateOverlayTransformCache()
    refreshOverlayTransform(canvasView, for: page)
  }

  private func viewportTarget(for request: ViewportRequest) -> (zoom: CGFloat, focus: CGPoint)? {
    guard let page = documentState?.activePage.page else { return nil }
    let pageGeometry = documentState?.activePage.geometry ?? .empty
    switch request {
    case .preserve:
      return nil
    case .fit:
      guard let zoom = usableFitScale() else { return nil }
      return (zoom, CGPoint(x: pageGeometry.mediaBox.width / 2, y: pageGeometry.mediaBox.height / 2))
    case .focus(let focus, let zoom):
      let currentFocus = currentCanonicalFocus() ?? CGPoint(
        x: pageGeometry.mediaBox.width / 2,
        y: pageGeometry.mediaBox.height / 2
      )
      let targetZoom = CGFloat(min(max(zoom ?? Double(documentView.scaleFactor), 0.1), 16))
      return (
        targetZoom,
        clampedViewportFocus(focus ?? currentFocus, at: targetZoom)
      )
    }
  }

  private func animateViewport(
    to target: (zoom: CGFloat, focus: CGPoint),
    page: PDFPage,
    completion: (() -> Void)? = nil
  ) {
    let startZoom = CGFloat(documentView.scaleFactor)
    let startFocus = currentCanonicalFocus() ?? target.focus
    let driver = ViewportAnimationDriver(duration: 0.16, update: { [weak self] progress in
      guard let self else { return }
      let zoom = startZoom + (target.zoom - startZoom) * progress
      let focus = CGPoint(
        x: startFocus.x + (target.focus.x - startFocus.x) * progress,
        y: startFocus.y + (target.focus.y - startFocus.y) * progress
      )
      self.applyInterpolatedViewport(zoom: zoom, focus: focus, page: page)
    }, finish: { [weak self] in
      guard let self, self.viewportAnimation != nil else { return }
      self.viewportAnimation = nil
      self.applyInterpolatedViewport(zoom: target.zoom, focus: target.focus, page: page)
      completion?()
    })
    viewportAnimation = driver
    driver.start()
  }

  private func applyInterpolatedViewport(zoom: CGFloat, focus: CGPoint, page: PDFPage) {
    documentView.scaleFactor = zoom
    documentView.go(to: destination(for: focus, page: page))
    documentView.layoutIfNeeded()
    invalidateOverlayTransformCache()
    refreshOverlayTransform(canvasView, for: page)
  }

  func cancelViewportAnimation() {
    viewportAnimation?.stop()
    viewportAnimation = nil
  }

  func setTextKeyboardOcclusion(_ bottom: CGFloat) {
    textKeyboardOcclusion = max(0, bottom.isFinite ? bottom : 0)
  }

  func resetTextViewportAvoidance() {
    textKeyboardOcclusion = 0
  }

  /// Moves the PDF viewport by a screen-space delta while preserving zoom.
  /// Positive deltas follow the user's finger, so the page content moves in
  /// the same direction as the supplied translation.
  func panViewport(by translation: CGPoint) {
    guard !disposed,
          let page = documentState?.activePage.page,
          documentView.bounds.width > 0,
          documentView.bounds.height > 0,
          translation.x.isFinite,
          translation.y.isFinite else { return }
    let center = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let pagePoint = documentView.convert(
      CGPoint(x: center.x - translation.x, y: center.y - translation.y),
      to: page)
    guard let focus = canonicalPoint(from: pagePoint) else { return }
    documentView.go(to: destination(for: focus, page: page))
    documentView.layoutIfNeeded()
    invalidateOverlayTransformCache()
    refreshOverlayTransform(canvasView, for: page)
  }

  func ensureTextVisible(_ rect: CGRect, padding: CGFloat) {
    guard rect.isNull == false,
          rect.minX.isFinite, rect.maxX.isFinite,
          rect.minY.isFinite, rect.maxY.isFinite else { return }
    let caret = textInteractionOverlay.convert(rect, to: container)
    let inset = max(0, padding.isFinite ? padding : 0)
    let visible = container.bounds.inset(by: UIEdgeInsets(
      top: inset, left: inset, bottom: textKeyboardOcclusion + inset, right: inset))
    var delta = CGPoint.zero
    if caret.maxY > visible.maxY { delta.y = visible.maxY - caret.maxY }
    else if caret.minY < visible.minY { delta.y = visible.minY - caret.minY }
    if caret.maxX > visible.maxX { delta.x = visible.maxX - caret.maxX }
    else if caret.minX < visible.minX { delta.x = visible.minX - caret.minX }
    guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }
    panViewport(by: delta)
  }

  func documentViewNavigationTouchBegan(_: InkPdfView) {
    pageTurnLifecycle.cancelSettlement()
    cancelViewportAnimation()
  }

  @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
    guard !disposed, !editMode, let page = documentState?.activePage.page else { return }
    let pageGeometry = documentState?.activePage.geometry ?? .empty
    if !isFittedToPage() {
      applyViewport(request: .fit, animated: true)
      return
    }
    let targetZoom = doubleTap?.zoom ?? 2.0
    guard targetZoom.isFinite, targetZoom > 0 else { return }
    let clampedTargetZoom = CGFloat(min(max(targetZoom, 0.1), 16))
    let currentZoom = documentView.scaleFactor
    guard currentZoom.isFinite, clampedTargetZoom > currentZoom else { return }

    let location = recognizer.location(in: documentView)
    let pdfPoint = documentView.convert(location, to: page)
    guard let tappedPoint = canonicalPoint(from: pdfPoint),
          tappedPoint.x.isFinite, tappedPoint.y.isFinite else { return }
    let focus = clampedViewportFocus(tappedPoint, at: clampedTargetZoom)
    guard focus.x.isFinite, focus.y.isFinite else { return }

    cancelViewportAnimation()
    let entersEditMode = doubleTap?.enterEditMode == true
    animateViewport(
      to: (zoom: clampedTargetZoom, focus: focus),
      page: page,
      completion: entersEditMode ? { [weak self] in
        self?.setInteractionMode(editing: true)
      } : nil
    )
  }

  func isFittedToPage() -> Bool {
    guard let page = documentState?.activePage.page,
          let pageGeometry = documentState?.activePage.geometry,
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
    guard let page = documentState?.activePage.page else { return nil }
    let viewCenter = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let pdfPoint = documentView.convert(viewCenter, to: page)
    return canonicalPoint(from: pdfPoint)
  }

  private func canonicalPoint(from pdfPoint: CGPoint) -> CGPoint? {
    let mediaBox = documentState?.activePage.geometry.mediaBox ?? .zero
    let x = pdfPoint.x - mediaBox.minX
    let y = mediaBox.maxY - pdfPoint.y
    guard x.isFinite, y.isFinite else { return nil }
    return clampedCanonicalPoint(CGPoint(x: x, y: y))
  }

  private func clampedCanonicalPoint(_ point: CGPoint) -> CGPoint {
    let mediaBox = documentState?.activePage.geometry.mediaBox ?? .zero
    return CGPoint(
      x: min(max(point.x, 0), mediaBox.width),
      y: min(max(point.y, 0), mediaBox.height)
    )
  }

  private func clampedViewportFocus(_ point: CGPoint, at zoom: CGFloat) -> CGPoint {
    let pageGeometry = documentState?.activePage.geometry ?? .empty
    let mediaBox = pageGeometry.mediaBox
    guard zoom.isFinite, zoom > 0,
          documentView.bounds.width > 0, documentView.bounds.height > 0 else {
      return clampedCanonicalPoint(point)
    }

    let visibleWidth = documentView.bounds.width / zoom
    let visibleHeight = documentView.bounds.height / zoom
    let rotation = ((pageGeometry.rotation % 360) + 360) % 360
    let visibleCanonicalWidth = rotation == 90 || rotation == 270 ? visibleHeight : visibleWidth
    let visibleCanonicalHeight = rotation == 90 || rotation == 270 ? visibleWidth : visibleHeight
    return CGPoint(
      x: clampedViewportCoordinate(point.x, pageLength: mediaBox.width,
                                    visibleLength: visibleCanonicalWidth),
      y: clampedViewportCoordinate(point.y, pageLength: mediaBox.height,
                                    visibleLength: visibleCanonicalHeight)
    )
  }

  private func clampedViewportCoordinate(
    _ value: CGFloat,
    pageLength: CGFloat,
    visibleLength: CGFloat
  ) -> CGFloat {
    let candidate = value.isFinite ? value : pageLength / 2
    guard visibleLength.isFinite, visibleLength > 0 else {
      return min(max(candidate, 0), pageLength)
    }
    if visibleLength >= pageLength { return pageLength / 2 }
    return min(max(candidate, visibleLength / 2), pageLength - visibleLength / 2)
  }

  func destination(for focus: CGPoint, page: PDFPage) -> PDFDestination {
    let mediaBox = documentState?.activePage.geometry.mediaBox ?? .zero
    let x = min(max(focus.x, 0), mediaBox.width) + mediaBox.minX
    let y = mediaBox.maxY - min(max(focus.y, 0), mediaBox.height)
    return PDFDestination(page: page, at: CGPoint(x: x, y: y))
  }

  static func parseViewport(_ options: ViewportOptions?) throws -> ViewportRequest {
    guard let options else { return .preserve }
    try validateViewport(options)
    guard options.x != nil || options.y != nil || options.zoom != nil else { return .fit }
    let focus = options.x.flatMap { x in
      options.y.map { y in CGPoint(x: x, y: y) }
    }
    return .focus(focus, zoom: options.zoom)
  }

  static func parseOpenViewport(_ options: ViewportOptions?) throws -> (zoom: Double?, focus: CGPoint?, fitToPage: Bool) {
    guard let options else { return (nil, nil, true) }
    try validateViewport(options)
    let focus = options.x.flatMap { x in
      options.y.map { y in CGPoint(x: x, y: y) }
    }
    if options.x == nil && options.y == nil && options.zoom == nil {
      return (nil, nil, true)
    }
    return (options.zoom, focus, false)
  }

  static func validateViewport(_ options: ViewportOptions) throws {
    if (options.x == nil) != (options.y == nil) {
      throw ViewportError.invalidOptions("x and y must be supplied together")
    }
    if let x = options.x, !x.isFinite {
      throw ViewportError.invalidOptions("x must be finite")
    }
    if let y = options.y, !y.isFinite {
      throw ViewportError.invalidOptions("y must be finite")
    }
    if let zoom = options.zoom, !zoom.isFinite || zoom <= 0 {
      throw ViewportError.invalidOptions("zoom must be finite and positive")
    }
  }


}
