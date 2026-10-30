import PDFKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

private final class SourceSelectionHighlightView: UIView {
  var copySelection: (() -> Void)?
  override var canBecomeFirstResponder: Bool { true }
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    action == #selector(copy(_:)) && copySelection != nil
  }
  override func copy(_ sender: Any?) { copySelection?() }
}

/// Retains UIKit's press timing/slop while exposing real, coalesced drag samples.
private final class SourceWordLongPress: UILongPressGestureRecognizer {
  var samples: (([CGPoint]) -> Void)?
  var navigationTakeover: (() -> Void)?
  private var initialPoint: CGPoint?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let view, initialPoint == nil { initialPoint = touches.first?.location(in: view) }
    if (event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) > 1 {
      navigationTakeover?()
    }
    guard state != .failed && state != .cancelled else { return }
    super.touchesBegan(touches, with: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    if state == .possible, let initialPoint, let view, let point = touches.first?.location(in: view),
       hypot(point.x - initialPoint.x, point.y - initialPoint.y) > allowableMovement {
      navigationTakeover?()
    }
    guard state != .failed && state != .cancelled else { return }
    deliver(touches, event: event)
    super.touchesMoved(touches, with: event)
  }

  override func reset() {
    super.reset()
    initialPoint = nil
  }

  func retire() {
    switch state {
    case .possible: state = .failed
    case .began, .changed: state = .cancelled
    default: break
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    deliver(touches, event: event)
    super.touchesEnded(touches, with: event)
  }

  private func deliver(_ touches: Set<UITouch>, event: UIEvent) {
    guard state == .began || state == .changed, let touch = touches.first, let view else { return }
    samples?((event.coalescedTouches(for: touch) ?? [touch]).map { $0.location(in: view) })
  }

  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
    if preventedGestureRecognizer is UIPinchGestureRecognizer { return false }
    return super.canPrevent(preventedGestureRecognizer)
  }
}

/// Viewer/main-owned transient source selection; never retains a reader lease or PDFPage.
final class InkSignPdfSourceTextSelectionController: NSObject, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
  private struct Binding: Equatable {
    let core: ObjectIdentifier
    let generation: UInt64
    let pageID: UUID
    let geometryRevision: UInt64
  }
  private weak var owner: ViewerCanvas?
  private let pasteboard: UIPasteboard
  private var binding: Binding?
  private var pressBinding: Binding?
  private var selection: InkSignPdfSourceTextSelection?
  private var resetting = false
  private var interactionToken: UInt64 = 0
  private let press = SourceWordLongPress()
  private let outsideTap = UITapGestureRecognizer()
  private let highlights = SourceSelectionHighlightView()
  private let highlightLayer = CAShapeLayer()
  private let boxLayer = CAShapeLayer()
  private lazy var editMenu = UIEditMenuInteraction(delegate: self)

  init(owner: ViewerCanvas, pasteboard: UIPasteboard = .general) {
    self.owner = owner
    self.pasteboard = pasteboard
    super.init()
    highlights.backgroundColor = .clear
    highlights.isUserInteractionEnabled = false
    highlightLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
    highlights.layer.addSublayer(highlightLayer)
    boxLayer.fillColor = UIColor.clear.cgColor
    boxLayer.strokeColor = UIColor.systemBlue.cgColor
    boxLayer.lineWidth = 1.5
    boxLayer.lineDashPattern = [5, 3]
    highlights.layer.addSublayer(boxLayer)
    press.minimumPressDuration = 0.5
    press.allowableMovement = 10
    press.numberOfTouchesRequired = 1
    press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    press.delegate = self
    press.addTarget(self, action: #selector(pressChanged))
    press.samples = { [weak self] points in self?.visit(points) }
    press.navigationTakeover = { [weak self] in self?.reset() }
    outsideTap.cancelsTouchesInView = false
    outsideTap.delegate = self
    outsideTap.require(toFail: owner.doubleTapGestureRecognizer)
    outsideTap.addTarget(self, action: #selector(tappedOutside))
    owner.documentView.addGestureRecognizer(press)
    owner.documentView.addGestureRecognizer(outsideTap)
    highlights.addInteraction(editMenu)
  }

  private func currentBinding() -> Binding? {
    guard let owner, owner.acceptsSourceTextSelection,
          let core = owner.attachedCore, let page = owner.viewerDocument?.activePage else { return nil }
    return Binding(core: ObjectIdentifier(core), generation: core.coordinator.generation,
      pageID: page.id, geometryRevision: page.geometryRevision)
  }

  func reset() {
    guard !resetting else { return }
    resetting = true
    interactionToken &+= 1
    selection = nil
    binding = nil
    pressBinding = nil
    highlights.copySelection = nil
    highlights.resignFirstResponder()
    boxLayer.path = nil
    highlightLayer.path = nil
    highlights.removeFromSuperview()
    editMenu.dismissMenu()
    // Leave the recognizer terminal until UIKit ends and resets this touch stream.
    press.retire()
    resetting = false
  }

  func presentationChanged() {
    guard let current = currentBinding() else { reset(); return }
    if binding.map({ $0 != current }) == true || pressBinding.map({ $0 != current }) == true { reset(); return }
    refreshHighlights()
    // UIKit owns menu visibility; this only repositions a menu that is still presented.
    editMenu.updateVisibleMenuPosition(animated: false)
  }

  func dispose() {
    reset()
    owner?.documentView.removeGestureRecognizer(press)
    owner?.documentView.removeGestureRecognizer(outsideTap)
    highlights.removeInteraction(editMenu)
    owner = nil
  }

  @objc private func pressChanged() {
    guard !resetting else { return }
    switch press.state {
    case .began:
      guard let owner, let captured = pressBinding, captured == currentBinding() else { return }
      beginSelection(at: press.location(in: owner.documentView))
    case .ended:
      finishSelection()
    case .cancelled, .failed:
      // A failed ordinary pan/tap does not dismiss a retained selection.
      if selection?.isDragging == true { reset() }
    default: break
    }
  }

  func beginSelection(at viewPoint: CGPoint) {
    guard let owner, let captured = currentBinding(), let page = owner.viewerDocument?.activePage,
          let point = owner.sourceCanonicalPoint(viewPoint) else { return }
    let words = page.prepared.sourceWords
    guard captured == currentBinding(),
          let word = words.hit(point, tolerance: owner.sourceTouchTolerance) else { return }
    editMenu.dismissMenu()
    interactionToken &+= 1
    binding = captured
    selection = InkSignPdfSourceTextSelection(index: words)
    selection?.begin(word)
    owner.documentView.clearSelection()
    refreshHighlights()
    UISelectionFeedbackGenerator().selectionChanged()
  }

  func visit(_ samples: [CGPoint]) {
    guard let owner, selection?.isDragging == true else { return }
    guard binding == currentBinding() else { reset(); return }
    for sample in samples {
      guard let point = owner.sourceCanonicalPoint(sample) else { continue }
      selection?.updateBox(to: point)
    }
    refreshHighlights()
  }

  @discardableResult
  func finishSelection() -> UIEditMenuConfiguration? {
    guard binding != nil, binding == currentBinding() else { reset(); return nil }
    selection?.finish()
    return showMenu()
  }

  func selectedCopyText() -> String? { selection?.copyText() }

  private func visibleRectangles(_ rectangles: [CGRect]? = nil) -> [CGRect] {
    guard let owner, let state = owner.viewerDocument else { return [] }
    let geometry = state.activePage.geometry
    let canonicalPage = CGRect(origin: .zero, size: geometry.visibleBox.size)
    return (rectangles ?? selection?.highlightRectangles ?? []).compactMap { rect -> CGRect? in
      let clipped = rect.intersection(canonicalPage)
      guard !clipped.isNull, !clipped.isEmpty else { return nil }
      let pdf = clipped.applying(geometry.canonicalToPDFTransform)
      let view = owner.documentView.convert(pdf, from: state.activePDFPage).intersection(owner.documentView.bounds)
      return view.isNull || view.isEmpty ? nil : view
    }
  }

  private func refreshHighlights() {
    guard let owner, selection != nil else { return }
    let overlay = owner.overlayProvider.overlayView
    if highlights.superview !== overlay { overlay.insertSubview(highlights, at: 0) }
    highlights.frame = overlay.bounds
    highlightLayer.frame = highlights.bounds
    boxLayer.frame = highlights.bounds
    let path = UIBezierPath()
    visibleRectangles().forEach { path.append(UIBezierPath(rect: highlights.convert($0, from: owner.documentView))) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    highlightLayer.path = path.cgPath
    let boxPath = UIBezierPath()
    if let box = selection?.selectionBox {
      visibleRectangles([box]).forEach { boxPath.append(UIBezierPath(rect: highlights.convert($0, from: owner.documentView))) }
    }
    boxLayer.path = boxPath.cgPath
    CATransaction.commit()
  }

  private func selectedBounds() -> CGRect? {
    let rects = visibleRectangles()
    guard let first = rects.first else { return nil }
    return rects.dropFirst().reduce(first) { $0.union($1) }
  }

  @discardableResult
  private func showMenu() -> UIEditMenuConfiguration? {
    guard let owner, let bounds = selectedBounds() else { return nil }
    let anchor = highlights.convert(CGPoint(x: bounds.midX, y: bounds.minY), from: owner.documentView)
    let configuration = UIEditMenuConfiguration(identifier: NSNumber(value: interactionToken), sourcePoint: anchor)
    highlights.copySelection = { [weak self] in
      guard let self, self.binding == self.currentBinding() else { return }
      if let text = self.selection?.copyText() { self.pasteboard.string = text }
      self.reset()
    }
    highlights.becomeFirstResponder()
    editMenu.presentEditMenu(with: configuration)
    return configuration
  }

  @objc private func tappedOutside() {
    guard let owner, selection != nil else { return }
    let point = outsideTap.location(in: owner.documentView)
    if !visibleRectangles().contains(where: { $0.contains(point) }) { reset() }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard let owner, owner.acceptsSourceTextSelection else { return false }
    if gestureRecognizer === outsideTap { return selection != nil }
    let point = touch.location(in: owner.documentView)
    let overlayPoint = owner.textInteractionOverlay.convert(point, from: owner.documentView)
    guard owner.textInteractionOverlay.hitTest(overlayPoint, with: nil) == nil else { return false }
    if gestureRecognizer === press { pressBinding = currentBinding() }
    return true
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === press else { return true }
    guard let owner, let pressBinding, pressBinding == currentBinding(), let page = owner.viewerDocument?.activePage,
          let point = owner.sourceCanonicalPoint(press.location(in: owner.documentView)) else { return false }
    return page.prepared.sourceWords.hit(point, tolerance: owner.sourceTouchTolerance) != nil
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === press, otherGestureRecognizer !== outsideTap,
          let owner, let view = otherGestureRecognizer.view,
          view === owner.documentView || view.isDescendant(of: owner.documentView) else { return false }
    // A pan waits for press admission: early movement fails the press, while a held
    // word owns the remaining drag. Pinch can take over through navigationTakeover.
    return !(otherGestureRecognizer is UIPinchGestureRecognizer)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === outsideTap || otherGestureRecognizer is UIPinchGestureRecognizer
  }

  func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                           suggestedActions: [UIMenuElement]) -> UIMenu? {
    guard (configuration.identifier as? NSNumber)?.uint64Value == interactionToken,
          selection?.copyText() != nil else { return nil }
    let menuToken = interactionToken
    func copyCommand(in elements: [UIMenuElement]) -> UICommand? {
      for element in elements {
        if let command = element as? UICommand, command.action == #selector(UIResponderStandardEditActions.copy(_:)) { return command }
        if let menu = element as? UIMenu, let command = copyCommand(in: menu.children) { return command }
      }
      return nil
    }
    guard let command = copyCommand(in: suggestedActions) else { return UIMenu(children: []) }
    return UIMenu(children: [UIAction(title: command.title, image: command.image) { [weak self] _ in
      guard let self, self.interactionToken == menuToken, self.binding == self.currentBinding() else { return }
      if let text = self.selection?.copyText() { self.pasteboard.string = text }
      self.reset()
    }])
  }

  func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                           targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
    guard (configuration.identifier as? NSNumber)?.uint64Value == interactionToken,
          let owner, let bounds = selectedBounds() else { return .zero }
    return highlights.convert(bounds, from: owner.documentView)
  }
}
