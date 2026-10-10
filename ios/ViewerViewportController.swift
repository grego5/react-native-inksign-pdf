import Foundation
import PDFKit
import UIKit
import NitroModules

protocol ViewerViewportHost: AnyObject {
  var container: UIView { get }
  var documentView: PDFView { get }
  var documentCoordinator: InkSignPdfDocumentCoordinator { get }
  var overlayProvider: PageOverlayProvider { get }
  var attachedOverlayPage: UUID? { get }
  var overlayTransformPage: UUID? { get }
  var pageToOverlayTransform: CGAffineTransform? { get }
  var disposed: Bool { get }
  var pagerDirection: PagerDirection? { get }
  var doubleTap: DoubleTapOptions? { get }
  var isEditingText: Bool { get }
  var onZoomChange: ((Double) -> Void)? { get }
  func cancelViewportInk()
  func refreshViewportOverlay(for pageID: UUID)
  func refreshViewportPresentation()
  func invalidateViewportOverlay()
  func followViewportCaret()
  func reportPageNavigationFailure(_ error: Error)
}

/// Sole owner of programmatic viewport mutation and temporary keyboard space.
final class ViewerViewportController {
  private weak var hostReference: (any ViewerViewportHost)?
  private var host: any ViewerViewportHost {
    guard let hostReference else { preconditionFailure("Viewport host must be alive during presentation") }
    return hostReference
  }
  private typealias ViewportError = InkSignView.ViewportError
  private unowned let interaction: ViewerInteractionCoordinator
  let motion = InkSignPdfViewportMotion()
  private(set) var requestID: UInt64 = 0
  private var isApplyingViewportFrame = false
  private var textKeyboardOcclusion: CGFloat = 0
  private weak var textInsetScrollView: UIScrollView?
  private var textInsetAdjustment: (baseBottom: CGFloat, appliedBottom: CGFloat)?
  private var keyboardFrameInScreen: CGRect?
  private var keyboardScreen: UIScreen?
  private var editing: Bool { host.isEditingText }
  private var keyboardAvoidanceEnabled = true
  private var keyboardObservers: [NSObjectProtocol] = []
  private var zoomReportWork: DispatchWorkItem?
  private var zoomReportSample: (UUID, CGFloat, CGFloat)?
  private var reportedZoomGeneration: UInt64?
  private var reportedZoomPage: UUID?
  private var reportedZoom: Double?
  private var container: UIView { host.container }
  private var documentView: PDFView { host.documentView }
  private var documentCoordinator: InkSignPdfDocumentCoordinator { host.documentCoordinator }
  private var overlayProvider: PageOverlayProvider { host.overlayProvider }
  private var disposed: Bool { host.disposed }
  private var pagerDirection: PagerDirection? { host.pagerDirection }
  private var doubleTap: DoubleTapOptions? { host.doubleTap }

  init(host: any ViewerViewportHost, interaction: ViewerInteractionCoordinator) {
    self.hostReference = host
    self.interaction = interaction
    for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
      keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
        queue: .main) { [weak self] notification in self?.keyboardFrameChanged(notification) })
    }
  }
  deinit { keyboardObservers.forEach(NotificationCenter.default.removeObserver) }
  func navigate(to page: PDFPage) { documentView.go(to: page) }
  @discardableResult
  func supersede() -> UInt64 {
    requestID &+= 1
    let id = requestID
    motion.cancel()
    return id
  }
  func cancelMotion() { motion.cancel() }
  func dispose() {
    supersede()
    zoomReportWork?.cancel()
    zoomReportWork = nil
    resetTextViewportAvoidance()
    keyboardObservers.forEach(NotificationCenter.default.removeObserver)
    keyboardObservers.removeAll()
  }
  func textEditingChanged() { updateKeyboardOcclusion() }
  func setKeyboardAvoidanceEnabled(_ enabled: Bool) {
    keyboardAvoidanceEnabled = enabled
    updateKeyboardOcclusion()
    if editing { host.followViewportCaret() }
  }
  private func keyboardFrameChanged(_ notification: Notification) {
    guard hostReference != nil, !disposed else { return }
    if notification.name == UIResponder.keyboardWillHideNotification {
      keyboardFrameInScreen = nil
      keyboardScreen = nil
    } else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
      keyboardFrameInScreen = frame.cgRectValue
      keyboardScreen = notification.object as? UIScreen
    }
    updateKeyboardOcclusion()
    if editing { host.followViewportCaret() }
  }
  private func updateKeyboardOcclusion() {
    guard keyboardAvoidanceEnabled, editing, let frame = keyboardFrameInScreen,
          let window = container.window else { resetTextViewportAvoidance(); return }
    let converted = (keyboardScreen ?? window.screen).coordinateSpace.convert(frame, to: container)
    let overlap = container.bounds.intersection(converted)
    setTextKeyboardOcclusion(overlap.isNull ? 0 : max(0, container.bounds.maxY - overlap.minY))
  }

  func applyPagerDirectionNow() {
    guard Thread.isMainThread else { return }
    interaction.cancelPresentation()
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
    let requestID = self.requestID
    if !preservingMotion { motion.cancel() }
    guard self.requestID == requestID, let state = documentCoordinator.document,
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
      host.refreshViewportOverlay(for: state.activePage.id)
    }
    isApplyingViewportFrame = false
    host.followViewportCaret()
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
    let requestID = self.requestID
    host.cancelViewportInk()
    let isCurrent = { [weak self, weak scroll] in
      guard let self, self.hostReference != nil, let scroll else { return false }
      return !self.disposed && self.documentView.window != nil &&
        self.documentCoordinator.generation == generation &&
        self.documentCoordinator.document?.activePage.id == pageID &&
        self.documentCoordinator.document?.activePage.geometryRevision == geometryRevision &&
        self.requestID == requestID && (modeSession.map(self.interaction.sessionIsCurrent) ?? true) &&
        self.pageViewportScrollView() === scroll
    }
    motion.start(
      from: ViewportTarget(zoom: CGFloat(start.zoom), focus: CGPoint(x: start.x, y: start.y)),
      to: target,
      update: { [weak self, weak scroll] frame in
        guard let self, let scroll, isCurrent() else { throw ViewportError.cancelled }
        let gestures = [scroll.panGestureRecognizer, scroll.pinchGestureRecognizer].compactMap { $0 }
        guard !gestures.contains(where: { $0.state == .began || $0.state == .changed }) else {
          throw ViewportError.cancelled
        }
        guard self.applyViewport(target: frame, preservingMotion: true) else { throw ViewportError.notReady }
      },
      completion: { [weak self] outcome in
        if let self, self.hostReference != nil { self.host.refreshViewportPresentation() }
        if case .success = outcome, !isCurrent() {
          completion(.failure(ViewportError.cancelled)); return
        }
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
      activeOverlayAttached: state.map {
        host.attachedOverlayPage == $0.activePage.id && documentView.currentPage === $0.activePage.page &&
          host.overlayTransformPage == $0.activePage.id && host.pageToOverlayTransform != nil
      } == true,
      fitScaleUsable: usableFitScale() != nil)
  }

  func usableFitScale() -> CGFloat? {
    guard documentView.bounds.width > 0, documentView.bounds.height > 0 else { return nil }
    let fitScale = documentView.scaleFactorForSizeToFit
    guard fitScale.isFinite, fitScale > 0 else { return nil }
    return min(max(fitScale, 0.1), 16)
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

  func setTextKeyboardOcclusion(_ bottom: CGFloat) {
    textKeyboardOcclusion = bottom
    reconcileTextViewportInset()
  }

  func resetTextViewportAvoidance() {
    textKeyboardOcclusion = 0
    restoreTextViewportInset()
  }

  func panViewport(by translation: CGPoint, preservingMotion: Bool = false) {
    let requestID = self.requestID
    if !preservingMotion { motion.cancel() }
    guard self.requestID == requestID, !disposed,
          let state = documentCoordinator.document,
          let page = documentView.currentPage,
          page === state.activePage.page,
          documentView.bounds.width > 0,
          documentView.bounds.height > 0,
          translation.x.isFinite,
          translation.y.isFinite else { return }
    host.cancelViewportInk()
    if movePageViewport(by: translation) { host.refreshViewportPresentation() }
  }

  private func pageViewportScrollView() -> UIScrollView? {
    guard let pageID = documentCoordinator.document?.activePage.id,
          host.attachedOverlayPage == pageID else { return nil }
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

  func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
    guard !disposed, !interaction.isInk,
          documentCoordinator.document != nil else { return }
    if !isFittedToPage() {
      let requestID = supersede()
      guard self.requestID == requestID else { return }
      if let target = viewportTarget(for: .fit) {
        animateViewport(target: target, modeSession: interaction.currentSession) { [weak self] outcome in
          if case .failure(let error) = outcome { self?.reportFailure(error) }
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
    let requestID = supersede()
    guard self.requestID == requestID else { return }
    animateViewport(target: ViewportTarget(zoom: clampedTargetZoom, focus: focus),
                    modeSession: interaction.currentSession) { [weak self] outcome in
      guard let self, self.hostReference != nil, !self.disposed else { return }
      switch outcome {
      case .success:
        if entersEditMode {
          self.interaction.invalidateSession()
          self.interaction.setBaseMode(ink: true)
        }
      case .failure(let error): self.reportFailure(error)
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

  private func currentDisplayedFocus() -> CGPoint? {
    guard let state = documentCoordinator.document,
          let page = documentView.currentPage,
          page === state.activePage.page else { return nil }
    let viewCenter = CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
    let pdfPoint = documentView.convert(viewCenter, to: page)
    return pdfPoint.applying(state.activePage.geometry.displayToPDFTransform.inverted())
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
      animateViewport(target: target, modeSession: interaction.currentSession) { [weak self] outcome in
        if case .failure(let error) = outcome { self?.reportFailure(error) }
      }
    }
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
      host.invalidateViewportOverlay()
      host.refreshViewportOverlay(for: pageID)
    }
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

  func scheduleZoomReport() {
    guard !disposed, let state = documentCoordinator.document,
          let fit = usableFitScale() else { return }
    let sample = (state.activePage.id, documentView.scaleFactor, fit)
    if let previous = zoomReportSample, previous == sample,
       reportedZoomGeneration == documentCoordinator.generation,
       reportedZoomPage == state.activePage.id,
       reportedZoom == Double(sample.1 / sample.2) { return }
    zoomReportSample = sample
    zoomReportWork?.cancel()
    queueZoomReport()
  }

  private func queueZoomReport() {
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.hostReference != nil, !self.disposed, let state = self.documentCoordinator.document else { return }
      if self.motion.isRunning || self.hasActiveViewportGesture(in: self.documentView) {
        self.queueZoomReport()
        return
      }
      guard let fit = self.usableFitScale() else { return }
      guard self.documentView.currentPage === state.activePage.page,
            self.host.attachedOverlayPage == state.activePage.id,
            self.host.pageToOverlayTransform != nil else { return }
      let zoom = Double(self.documentView.scaleFactor / fit)
      self.zoomReportSample = (state.activePage.id, self.documentView.scaleFactor, fit)
      if self.reportedZoomGeneration != self.documentCoordinator.generation ||
         self.reportedZoomPage != state.activePage.id || self.reportedZoom != zoom {
        self.reportedZoomGeneration = self.documentCoordinator.generation
        self.reportedZoomPage = state.activePage.id
        self.reportedZoom = zoom
        self.host.onZoomChange?(zoom)
      }
    }
    zoomReportWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
  }

  private func hasActiveViewportGesture(in view: UIView) -> Bool {
    if let scroll = view as? UIScrollView,
       scroll.isTracking || scroll.isDragging || scroll.isDecelerating || scroll.isZooming || scroll.isZoomBouncing {
      return true
    }
    return view.subviews.contains { hasActiveViewportGesture(in: $0) }
  }
  private func reportFailure(_ error: Error) {
    guard let hostReference, !hostReference.disposed else { return }
    hostReference.reportPageNavigationFailure(error)
  }
}

extension InkSignView: ViewerViewportHost {
  var isEditingText: Bool { textInteractionOverlay.hasActiveEditor }
  func cancelViewportInk() { cancelActiveStroke() }
  func refreshViewportOverlay(for pageID: UUID) { refreshOverlayTransform(canvasView, for: pageID) }
  func refreshViewportPresentation() { refreshActiveOverlayTransform() }
  func invalidateViewportOverlay() { invalidateOverlayTransformCache() }
  func followViewportCaret() { textInteractionOverlay.followCaretForViewportChange() }
}
