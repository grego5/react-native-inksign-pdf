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

struct ViewportTarget: Equatable {
  let zoom: CGFloat
  let focus: CGPoint
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

extension InkSignView {
  @discardableResult
  func applyViewport(target: ViewportTarget) -> Bool {
    guard let page = documentCoordinator.document?.activePage.page else { return false }
    documentView.minScaleFactor = 0.1
    documentView.maxScaleFactor = 16
    documentView.autoScales = false
    guard documentView.applyViewport(zoom: target.zoom,
                                     focus: target.focus,
                                     generation: documentCoordinator.generation) else { return false }
    invalidateOverlayTransformCache()
    refreshOverlayTransform(canvasView, for: page)
    return true
  }

  func applyModeTransition(toEditing: Bool, request: ViewportRequest) throws {
    try requireViewportReady(request: request)
    cancelPendingPageSwitch()
    pageTurnLifecycle.cancelUncommittedTurn()
    cancelActiveStroke()
    setInteractionMode(editing: toEditing)
    applyViewport(request: request, animated: true)
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
      activeOverlayAttached: state.map { attachedOverlayPage === $0.activePage.page } == true,
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
          attachedOverlayPage === state.activePage.page,
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
            attachedOverlayPage === state.activePage.page,
            overlayTransformPage === state.activePage.page,
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
      documentView.removePage()
      setInteractionMode(editing: false, interactionsEnabled: false)
      return
    }
    let index = state.activePageIndex
    documentView.installPage(index: index,
                             page: state.activePage.page,
                             geometry: state.activePage.geometry,
                             session: state.pdfiumSession,
                             generation: documentCoordinator.generation)
    overlayDidDisplay(canvasView, for: state.activePage.page)
    if let target = pending?.previousViewport {
      _ = applyViewport(target: target)
    }
    setInteractionMode(editing: pending?.previousEditing ?? false)
  }

  func currentViewportSnapshot() throws -> Viewport {
    try requireViewportReady(request: .preserve)
    guard let state = documentCoordinator.document,
          let transform = documentView.viewportTransform else {
      throw ViewportError.notReady
    }
    let viewCenter = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let focus = transform.clampedCanonicalPoint(fromView: viewCenter)
    let mediaBox = state.activePage.geometry.mediaBox
    let x = focus.x
    let y = focus.y
    let zoom = Double(transform.zoom)
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
    guard let page = documentCoordinator.document?.activePage.page else { return }
    cancelViewportAnimation()
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
      guard let target = viewportTarget(for: request) else { return }
      _ = applyViewport(target: target)
    case .focus:
      guard let target = viewportTarget(for: request) else { return }
      _ = applyViewport(target: target)
    }
    if case .preserve = request {
      invalidateOverlayTransformCache()
      refreshOverlayTransform(canvasView, for: page)
    }
  }

  private func viewportTarget(for request: ViewportRequest) -> ViewportTarget? {
    guard let page = documentCoordinator.document?.activePage.page else { return nil }
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

  private func animateViewport(
    to target: ViewportTarget,
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
    guard documentView.currentPage === page,
          documentView.applyViewport(zoom: zoom,
                                     focus: focus,
                                     generation: documentCoordinator.generation) else { return }
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
          let page = documentCoordinator.document?.activePage.page,
          let viewport = documentView.viewportTransform,
          documentView.bounds.width > 0,
          documentView.bounds.height > 0,
          translation.x.isFinite,
          translation.y.isFinite else { return }
    cancelActiveStroke()
    let center = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let focus = viewport.clampedCanonicalPoint(fromView: CGPoint(
      x: center.x - translation.x,
      y: center.y - translation.y))
    guard documentView.applyViewport(zoom: documentView.scaleFactor,
                                     focus: focus,
                                     generation: documentCoordinator.generation) else { return }
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
    guard !disposed, !editMode, let page = documentCoordinator.document?.activePage.page else { return }
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
    guard let viewport = documentView.viewportTransform else { return }
    let tappedPoint = viewport.clampedCanonicalPoint(fromView: location)
    guard tappedPoint.x.isFinite, tappedPoint.y.isFinite else { return }
    let focus = tappedPoint

    cancelViewportAnimation()
    let entersEditMode = doubleTap?.enterEditMode == true
    animateViewport(
      to: ViewportTarget(zoom: clampedTargetZoom, focus: focus),
      page: page,
      completion: entersEditMode ? { [weak self] in
        self?.setInteractionMode(editing: true)
      } : nil
    )
  }

  func isFittedToPage() -> Bool {
    guard let page = documentCoordinator.document?.activePage.page,
          let pageGeometry = documentCoordinator.document?.activePage.geometry,
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
    guard let viewport = documentView.viewportTransform else { return false }
    let pageCenterInView = viewport.viewPoint(fromPDF: pageCenter)
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
    guard documentCoordinator.document?.activePage.page != nil,
          let viewport = documentView.viewportTransform else { return nil }
    let viewCenter = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    return viewport.clampedCanonicalPoint(fromView: viewCenter)
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
