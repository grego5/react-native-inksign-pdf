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
  /// Current displayed page coordinates.
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
  func requestPageCoords() throws -> Promise<PageCoords> {
    try performOnMainSync {
      self.invalidateModeSession()
      return try self.pickPageCoords(modeSession: nil)
    }
  }

  func requestSessionPageCoords(_ token: InkSignPdfModeSessionToken) throws -> Promise<PageCoords> {
    try performOnMainSync {
      try self.requireModeSession(token)
      return try self.pickPageCoords(modeSession: token)
    }
  }

  private func pickPageCoords(modeSession: InkSignPdfModeSessionToken?) throws -> Promise<PageCoords> {
    try performOnMainSync {
      guard !self.disposed else { throw LoadError.cancelled }
      self.cancelCoordinateRequest()
      if let modeSession { try self.requireModeSession(modeSession) }
      else if self.currentModeSession != nil { throw LoadError.cancelled }
      let request = CoordinateRequest()
      request.modeSession = modeSession
      self.pendingPageCoords = request
      // Admission follows FIFO; the interactive wait does not occupy that queue.
      self.enqueueViewerCommand(presentation: true, modeSession: modeSession) {
        guard self.pendingPageCoords === request else { throw LoadError.cancelled }
        guard self.documentCoordinator.document != nil else { throw TextError.documentNotOpen }
        try self.applyModeTransition(toEditing: false, request: .preserve)
        guard self.pendingPageCoords === request,
              let page = self.documentCoordinator.document?.activePage else { throw LoadError.cancelled }
        request.target = CoordinateTarget(generation: self.documentCoordinator.generation,
                                          pageID: page.id, geometryRevision: page.geometryRevision)
        self.configureCoordinateTapPriority(in: self.documentView)
        self.coordinateTapGestureRecognizer.isEnabled = true
        self.emitChange()
        return Promise<Void>.resolved()
      }.catch { [weak self] error in
        self?.performOnMain {
          guard let self, self.pendingPageCoords === request else { return }
          self.cancelCoordinateRequest(error: error)
        }
      }
      return request.result.promise
    }
  }

  private func configureCoordinateTapPriority(in view: UIView) {
    for case let tap as UITapGestureRecognizer in view.gestureRecognizers ?? [] {
      if tap !== coordinateTapGestureRecognizer { tap.require(toFail: coordinateTapGestureRecognizer) }
    }
    view.subviews.forEach { configureCoordinateTapPriority(in: $0) }
  }

  func cancelCoordinateRequest(error: Error = LoadError.cancelled) {
    let pending = pendingPageCoords
    pendingPageCoords = nil
    coordinateTapGestureRecognizer.isEnabled = false
    if let pending { restoreCoordinateMode(pending) }
    if pending?.target != nil { emitChange() }
    pending?.result.reject(error)
  }

  private func restoreCoordinateMode(_ request: CoordinateRequest) {
    guard request.target != nil, let token = request.modeSession, modeSessionIsCurrent(token) else { return }
    do {
      setInteractionMode(editing: token.mode == .ink)
      try requireModeSession(token)
      if token.mode == .text {
        try textInteractionOverlay.armPlacement(generation: token.generation, options: token.textOptions)
      }
    }
    catch { request.result.reject(error) }
  }

  @objc func handleCoordinateTap(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended, !disposed,
          let pending = pendingPageCoords,
          let target = pending.target,
          let document = documentCoordinator.document else { return }
    guard coordinateTargetIsCurrent(target) else { cancelCoordinateRequest(); return }
    let location = recognizer.location(in: documentView)
    guard let page = documentView.page(for: location, nearest: false),
          page === document.activePage.page else { return }
    let index = document.activePageIndex
    let targetPage = document.activePage
    let point = documentView.convert(location, to: page)
      .applying(targetPage.geometry.displayToPDFTransform.inverted())
    let size = targetPage.geometry.displaySize
    guard point.x.isFinite, point.y.isFinite,
          point.x >= 0, point.x <= size.width,
          point.y >= 0, point.y <= size.height else { return }
    pendingPageCoords = nil
    coordinateTapGestureRecognizer.isEnabled = false
    restoreCoordinateMode(pending)
    emitChange()
    guard pending.modeSession.map(modeSessionIsCurrent) ?? true,
          coordinateTargetIsCurrent(target) else { pending.result.reject(LoadError.cancelled); return }
    pending.result.resolve(PageCoords(pageId: targetPage.id.uuidString, pageIndex: Double(index),
                              x: Double(point.x), y: Double(point.y)))
  }

  func coordinateTargetIsCurrent(_ target: CoordinateTarget) -> Bool {
    guard !disposed, let page = documentCoordinator.document?.activePage else { return false }
    return documentCoordinator.generation == target.generation &&
      page.id == target.pageID && page.geometryRevision == target.geometryRevision
  }

  func applyPagerDirection() {
    performOnMain { [weak self] in self?.applyPagerDirectionNow() }
  }

  func applyPagerDirectionNow() {
    guard Thread.isMainThread else { return }
    cancelPendingPageSwitch()
    let currentPage = documentView.currentPage
    let currentDestination = documentView.currentDestination
    let currentScale = documentView.scaleFactor
    switch pagerDirection {
    case .ltr: documentView.semanticContentAttribute = .forceLeftToRight
    case .rtl: documentView.semanticContentAttribute = .forceRightToLeft
    case .auto, .none: documentView.semanticContentAttribute = .unspecified
    }
    if let currentDestination {
      documentView.go(to: currentDestination)
      documentView.scaleFactor = currentScale
    } else if let currentPage {
      documentView.go(to: currentPage)
      documentView.scaleFactor = currentScale
    }
  }

  @discardableResult
  func applyViewport(target: ViewportTarget, preservingMotion: Bool = false) -> Bool {
    if !preservingMotion { viewportMotion.cancel() }
    guard let state = documentCoordinator.document,
          documentView.currentPage === state.activePage.page,
          documentView.bounds.width > 0, documentView.bounds.height > 0,
          let scroll = pageViewportScrollView(),
          scroll.bounds.width > 0, scroll.bounds.height > 0,
          let content = scroll.delegate?.viewForZooming?(in: scroll) else { return false }
    documentView.autoScales = false
    let zoom = min(max(target.zoom, documentView.minScaleFactor), documentView.maxScaleFactor)
    let geometry = state.activePage.geometry
    func contentPoint(_ point: CGPoint) -> CGPoint {
      content.convert(documentView.convert(point.applying(geometry.displayToPDFTransform),
                                            from: state.activePage.page), from: documentView)
    }
    let focus = contentPoint(target.focus)
    let unitX = contentPoint(CGPoint(x: target.focus.x + 1, y: target.focus.y))
    let contentScale = hypot(unitX.x - focus.x, unitX.y - focus.y)
    guard contentScale.isFinite, contentScale > 0,
          focus.x.isFinite, focus.y.isFinite else { return false }
    let nativeZoom = zoom / contentScale
    let size = CGSize(width: scroll.bounds.width / nativeZoom,
                      height: scroll.bounds.height / nativeZoom)
    let rect = CGRect(x: focus.x - size.width / 2, y: focus.y - size.height / 2,
                      width: size.width, height: size.height)
    isApplyingViewportFrame = true
    UIView.performWithoutAnimation {
      scroll.minimumZoomScale = documentView.minScaleFactor / contentScale
      scroll.maximumZoomScale = documentView.maxScaleFactor / contentScale
      // Let PDFKit calculate its zoom-dependent insets before adding keyboard space.
      restoreTextViewportInset()
      scroll.zoom(to: rect, animated: false)
      scroll.layoutIfNeeded()
      documentView.layoutIfNeeded()
      reconcileTextViewportInset(scroll)
      let focusedPoint = documentView.convert(target.focus.applying(geometry.displayToPDFTransform),
                                              from: state.activePage.page)
      _ = movePageViewport(by: CGPoint(x: documentView.bounds.midX - focusedPoint.x,
                                       y: documentView.bounds.midY - focusedPoint.y))
      refreshOverlayTransform(canvasView, for: state.activePage.id)
    }
    isApplyingViewportFrame = false
    textInteractionOverlay.followCaretForViewportChange()
    return true
  }

  func animateViewport(target: ViewportTarget,
                       modeSession: InkSignPdfModeSessionToken? = nil,
                       completion: @escaping (Result<Void, Error>) -> Void) {
    guard let page = documentCoordinator.document?.activePage,
          let scroll = pageViewportScrollView() else {
      completion(.failure(ViewportError.notReady)); return
    }
    let start: Viewport
    do { start = try currentViewportSnapshot() }
    catch { completion(.failure(error)); return }
    let generation = documentCoordinator.generation
    let pageID = page.id
    let geometryRevision = page.geometryRevision
    let requestID = fieldFocusRequestID
    cancelActiveStroke()
    viewportMotion.start(
      from: ViewportTarget(zoom: CGFloat(start.zoom), focus: CGPoint(x: start.x, y: start.y)),
      to: target,
      update: { [weak self, weak scroll] frame in
        guard let self, let scroll, !self.disposed,
              self.documentView.window != nil,
              self.documentCoordinator.generation == generation,
              self.documentCoordinator.document?.activePage.id == pageID,
              self.documentCoordinator.document?.activePage.geometryRevision == geometryRevision,
              self.fieldFocusRequestID == requestID,
              modeSession.map(self.modeSessionIsCurrent) ?? true,
              self.pageViewportScrollView() === scroll else { throw ViewportError.cancelled }
        let gestures = [scroll.panGestureRecognizer, scroll.pinchGestureRecognizer].compactMap { $0 }
        guard !gestures.contains(where: { $0.state == .began || $0.state == .changed }) else {
          throw ViewportError.cancelled
        }
        guard self.applyViewport(target: frame, preservingMotion: true) else { throw ViewportError.notReady }
      },
      completion: { [weak self] outcome in
        self?.refreshActiveOverlayTransform()
        completion(outcome)
      })
  }

  func fieldFocusTarget(ruleY: CGFloat,
                        horizontalFocus: CGFloat,
                        zoom: Double,
                        verticalAnchor: FieldFocusVerticalAnchor,
                        edgeOffset: Double) -> ViewportTarget? {
    guard let state = documentCoordinator.document,
          documentView.currentPage === state.activePage.page,
          documentView.bounds.height > 0,
          zoom.isFinite, edgeOffset.isFinite else { return nil }
    let targetZoom = min(max(CGFloat(zoom), documentView.minScaleFactor), documentView.maxScaleFactor)
    guard targetZoom.isFinite, targetZoom > 0 else { return nil }
    let keyboardOcclusion = min(max(textKeyboardOcclusion, 0), documentView.bounds.height)
    let usableHeight = documentView.bounds.height - keyboardOcclusion
    let visibleHeight = usableHeight / targetZoom
    let offset = min(CGFloat(edgeOffset), visibleHeight / 2)
    let keyboardCenterShift = keyboardOcclusion / (2 * targetZoom)
    let focusY: CGFloat
    switch verticalAnchor {
    case .top:
      focusY = ruleY + visibleHeight / 2 - offset + keyboardCenterShift
    case .bottom:
      focusY = ruleY - visibleHeight / 2 + offset + keyboardCenterShift
    case .center:
      focusY = ruleY + keyboardCenterShift
    }
    let geometry = state.activePage.geometry
    let pageHeight = geometry.displaySize.height
    let fullVisibleHeight = documentView.bounds.height / targetZoom
    let constrainedY: CGFloat
    if fullVisibleHeight >= pageHeight {
      constrainedY = pageHeight / 2
    } else {
      constrainedY = min(max(focusY, fullVisibleHeight / 2), pageHeight - fullVisibleHeight / 2)
    }
    return ViewportTarget(zoom: targetZoom,
                          focus: CGPoint(x: horizontalFocus, y: constrainedY))
  }

  func applyModeTransition(toEditing: Bool, request: ViewportRequest) throws {
    try requireViewportReady(request: request)
    fieldFocusRequestID &+= 1
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
          documentCoordinator.isCurrent(pending.operation),
          !disposed else {
      return false
    }

    guard pending.phase == .awaitingReadiness,
          let state = documentCoordinator.document,
          state.activePageIndex == 0,
          documentView.document === state.document,
          documentView.currentPage === state.activePage.page,
          attachedOverlayPage == state.activePage.id,
          state.activePage.geometry.isValid,
          documentView.bounds.width > 0,
          documentView.bounds.height > 0 else {
      return false
    }
    if pending.fitToPage, usableFitScale() == nil { return false }
    guard let target = openViewportTarget(for: pending) else { return false }
    var completing = pending
    completing.phase = .completing
    pendingOpen = completing
    do {
      guard applyViewport(target: target),
            attachedOverlayPage == state.activePage.id,
            overlayTransformPage == state.activePage.id,
            pageToOverlayTransform != nil else {
        throw ViewportError.notReady
      }
      guard pendingOpen?.operation.id == pending.operation.id,
            documentCoordinator.isCurrent(pending.operation), !disposed else { return true }
      let pageInfo = toPublicPageInfo(try currentPageInfo())
      applyInteractionMode(editing: false, interactionsEnabled: true)
      pendingOpen = nil
      documentCoordinator.settle(pending.operation, succeeded: true)
      pending.settlement.resolve(pageInfo)
      emitChange(force: true)
      return true
    } catch {
      failOpenAttempt(error: error, pending: completing)
      return true
    }
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
    let geometry = state.activePage.geometry
    let focus = pdfFocus.applying(geometry.displayToPDFTransform.inverted())
    let x = min(max(focus.x, 0), geometry.displaySize.width)
    let y = min(max(focus.y, 0), geometry.displaySize.height)
    let zoom = Double(documentView.scaleFactor)
    guard x.isFinite, y.isFinite, zoom.isFinite, zoom > 0 else {
      throw ViewportError.notReady
    }
    return Viewport(
      x: Double(x),
      y: Double(y),
      zoom: zoom,
    )
  }

  func applyViewport(request: ViewportRequest) {
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

  func viewportTarget(for request: ViewportRequest) -> ViewportTarget? {
    let pageGeometry = documentCoordinator.document?.activePage.geometry ?? .empty
    switch request {
    case .preserve:
      return nil
    case .fit:
      guard let zoom = usableFitScale() else { return nil }
      return ViewportTarget(
        zoom: zoom,
        focus: CGPoint(x: pageGeometry.displaySize.width / 2,
                       y: pageGeometry.displaySize.height / 2))
    case .focus(let focus, let zoom):
      let currentFocus = currentDisplayedFocus() ?? CGPoint(
        x: pageGeometry.displaySize.width / 2,
        y: pageGeometry.displaySize.height / 2
      )
      let targetZoom = CGFloat(zoom ?? Double(documentView.scaleFactor))
      return ViewportTarget(zoom: targetZoom, focus: focus ?? currentFocus)
    }
  }

  private func openViewportTarget(for pending: PendingOpen) -> ViewportTarget? {
    guard let state = documentCoordinator.document else { return nil }
    let size = state.activePage.geometry.displaySize
    let focus = pending.focus ?? CGPoint(x: size.width / 2, y: size.height / 2)
    if pending.fitToPage {
      guard let zoom = usableFitScale() else { return nil }
      return ViewportTarget(
        zoom: zoom,
        focus: CGPoint(x: size.width / 2, y: size.height / 2))
    }
    return ViewportTarget(zoom: CGFloat(pending.zoom ?? 1), focus: focus)
  }

  func setTextKeyboardOcclusion(_ bottom: CGFloat) {
    textKeyboardOcclusion = bottom
    reconcileTextViewportInset()
  }

  func resetTextViewportAvoidance() {
    textKeyboardOcclusion = 0
    restoreTextViewportInset()
  }

  /// Moves the PDF viewport by a screen-space delta while preserving zoom.
  /// Positive deltas follow the user's finger, so the page content moves in
  /// the same direction as the supplied translation.
  func panViewport(by translation: CGPoint, preservingMotion: Bool = false) {
    if !preservingMotion { viewportMotion.cancel() }
    guard !disposed,
          let state = documentCoordinator.document,
          let page = documentView.currentPage,
          page === state.activePage.page,
          documentView.bounds.width > 0,
          documentView.bounds.height > 0,
          translation.x.isFinite,
          translation.y.isFinite else { return }
    cancelActiveStroke()
    if movePageViewport(by: translation) { refreshActiveOverlayTransform() }
  }

  /// The document content's enclosing scroll view pans the page; its outer
  /// page-controller scroll view owns paging and must keep its offset.
  private func pageViewportScrollView() -> UIScrollView? {
    guard let pageID = documentCoordinator.document?.activePage.id,
          attachedOverlayPage == pageID else { return nil }
    // Start above the page overlay, skipping its PKCanvasView scroll view.
    var ancestor = overlayProvider.overlayView.superview
    while let view = ancestor, view !== documentView {
      if let scroll = view as? UIScrollView { return scroll }
      ancestor = view.superview
    }
    return nil
  }

  private func movePageViewport(by translation: CGPoint) -> Bool {
    guard let scroll = pageViewportScrollView() else { return false }
    scroll.layoutIfNeeded()
    reconcileTextViewportInset(scroll)
    let origin = scroll.convert(CGPoint.zero, from: documentView)
    let moved = scroll.convert(translation, from: documentView)
    let inset = scroll.adjustedContentInset
    let minX = -inset.left
    let minY = -inset.top
    let maxX = max(minX, scroll.contentSize.width - scroll.bounds.width + inset.right)
    let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
    scroll.setContentOffset(CGPoint(
      x: min(max(scroll.contentOffset.x - (moved.x - origin.x), minX), maxX),
      y: min(max(scroll.contentOffset.y - (moved.y - origin.y), minY), maxY)), animated: false)
    return true
  }

  func reconcileTextViewportInset() {
    guard !isApplyingViewportFrame else { return }
    if let scroll = pageViewportScrollView() { reconcileTextViewportInset(scroll) }
    else { restoreTextViewportInset() }
  }

  private func reconcileTextViewportInset(_ scroll: UIScrollView) {
    guard textKeyboardOcclusion > 0 else { restoreTextViewportInset(); return }
    if textInsetScrollView !== scroll {
      restoreTextViewportInset()
      textInsetScrollView = scroll
    }
    var inset = scroll.contentInset
    // Only our last bottom-inset write contains the recorded keyboard addition.
    // A changed bottom inset belongs to PDFKit's current page geometry.
    if let adjustment = textInsetAdjustment, inset.bottom == adjustment.appliedBottom {
      inset.bottom = adjustment.baseBottom
    }
    let baseBottom = inset.bottom
    let origin = scroll.convert(CGPoint.zero, from: documentView)
    let keyboard = scroll.convert(CGPoint(x: 0, y: textKeyboardOcclusion), from: documentView)
    inset.bottom += abs(keyboard.y - origin.y)
    textInsetAdjustment = (baseBottom: baseBottom, appliedBottom: inset.bottom)
    if scroll.contentInset != inset { scroll.contentInset = inset }
  }

  private func restoreTextViewportInset() {
    let scroll = textInsetScrollView
    let adjustment = textInsetAdjustment
    textInsetScrollView = nil
    textInsetAdjustment = nil
    if let scroll, let adjustment, scroll.contentInset.bottom == adjustment.appliedBottom {
      var inset = scroll.contentInset
      inset.bottom = adjustment.baseBottom
      scroll.contentInset = inset
    }
  }

  func ensureTextVisible(outline: CGRect, caret: CGRect) {
    guard !isApplyingViewportFrame else { return }
    let visible = container.bounds.inset(by: UIEdgeInsets(
      top: 0, left: 0, bottom: textKeyboardOcclusion, right: 0))
    let delta = InkSignPdfTextViewportGeometry.panDelta(outline: outline,
                                                       caret: caret,
                                                       visibleBounds: visible)
    guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }
    panViewport(by: delta, preservingMotion: true)
  }

  @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
    guard !disposed, !editMode,
          documentCoordinator.document != nil else { return }
    if !isFittedToPage() {
      fieldFocusRequestID &+= 1
      if let target = viewportTarget(for: .fit) {
        animateViewport(target: target, modeSession: currentModeSession) { [weak self] outcome in
          if case .failure(let error) = outcome { self?.reportPageNavigationFailure(error) }
        }
      }
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
    guard let geometry = documentCoordinator.document?.activePage.geometry else { return }
    let tappedPoint = pdfPoint.applying(geometry.displayToPDFTransform.inverted())
    guard tappedPoint.x.isFinite, tappedPoint.y.isFinite else { return }
    let focus = tappedPoint

    let entersEditMode = doubleTap?.enterEditMode == true
    fieldFocusRequestID &+= 1
    animateViewport(target: ViewportTarget(zoom: clampedTargetZoom, focus: focus),
                    modeSession: currentModeSession) { [weak self] outcome in
      guard let self else { return }
      switch outcome {
      case .success:
        if entersEditMode {
          self.invalidateModeSession()
          self.setInteractionMode(editing: true)
        }
      case .failure(let error): self.reportPageNavigationFailure(error)
      }
    }
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

  private func currentDisplayedFocus() -> CGPoint? {
    guard let state = documentCoordinator.document,
          let page = documentView.currentPage,
          page === state.activePage.page else { return nil }
    let viewCenter = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let pdfPoint = documentView.convert(viewCenter, to: page)
    return pdfPoint.applying(state.activePage.geometry.displayToPDFTransform.inverted())
  }

  static func parseViewport(_ options: ViewportOptions?) -> ViewportRequest {
    guard let options else { return .preserve }
    guard options.x != nil || options.y != nil || options.zoom != nil else { return .fit }
    let focus = options.x.flatMap { x in
      options.y.map { y in CGPoint(x: x, y: y) }
    }
    return .focus(focus, zoom: options.zoom)
  }

  func applyTextPlacementViewport(_ options: TextModeOptions?, editorFocus: CGPoint) {
    guard let options else { return }
    let target: ViewportTarget?
    if options.x != nil || options.y != nil || options.zoom != nil {
      let focus = options.x.map { CGPoint(x: $0, y: options.y!) } ?? editorFocus
      target = ViewportTarget(zoom: CGFloat(options.zoom ?? Double(documentView.scaleFactor)),
                              focus: focus)
    } else if options.direction == nil && options.width == nil && options.height == nil &&
      options.maxLines == nil && options.alignment == nil && options.verticalAnchor == nil {
      target = viewportTarget(for: .fit)
    } else {
      target = nil
    }
    if let target {
      animateViewport(target: target, modeSession: currentModeSession) { [weak self] outcome in
        if case .failure(let error) = outcome { self?.reportPageNavigationFailure(error) }
      }
    }
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
