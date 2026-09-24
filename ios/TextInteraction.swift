import CoreGraphics
import UIKit

private let defaultTextFontSize: CGFloat = 16
private let minimumTextFontSize: CGFloat = 8
private let maximumTextFontSize: CGFloat = 72
private let textFontSizeStep: CGFloat = 1
private let textEditorInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

/// Owns transient selection, editing, and movement presentation for page text.
/// The page history remains the only owner of committed annotation values.
final class InkSignPdfTextInteractionOverlay: UIView, UITextViewDelegate,
                                             UIGestureRecognizerDelegate {
  private struct EditingState {
    let id: String
    let generation: UInt64
    let pageIndex: Int
    let original: InkSignPdfTextAnnotation?
    var position: CGPoint
    var fontSize: CGFloat
    var isRTL: Bool
    var anchorX: CGFloat
    let textColor: String
  }

  private struct PlacementState {
    let generation: UInt64
    let pageIndex: Int
  }

  private struct DragState {
    let generation: UInt64
    let pageIndex: Int
    let original: InkSignPdfTextAnnotation
    let startPoint: CGPoint
    var position: CGPoint
  }

  private enum InteractionState {
    case idle
    case placing(PlacementState)
    case editing(EditingState)
    case dragging(DragState)
    case selected(id: String)
  }

  weak var owner: InkSignView?
  private var defaultFontSize = defaultTextFontSize
  private var defaultTextColor = "#000000"
  private var requestedTextDirectionRtl: Bool?
  private var outlineColor = UIColor(white: 0.25, alpha: 0.75)
  private var selectedOutlineColor = UIColor(white: 0.25, alpha: 0.75)
  private var editorBackgroundColor: UIColor?
  private var selectedBackgroundColor: UIColor?
  private var interactionState: InteractionState = .idle
  private var editor: UITextView?
  private var settlingEditor = false
  private var lastEditorContentSize = CGSize.zero
  private var keyboardAvoidanceEnabled = true
  private var caretFollowEnabled = false
  private var keyboardFrameInScreen: CGRect?
  private var keyboardObserver: NSObjectProtocol?
  private var keyboardHideObserver: NSObjectProtocol?
  private let outlineStrokeWidth: CGFloat = 2

  var onInteractionModeChanged: (() -> Void)?

  private lazy var tapRecognizer: UITapGestureRecognizer = {
    let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    recognizer.delegate = self
    recognizer.cancelsTouchesInView = false
    return recognizer
  }()

  lazy var placementTapRecognizer: UITapGestureRecognizer = {
    let recognizer = UITapGestureRecognizer(target: self,
                                            action: #selector(handlePlacementTap(_:)))
    recognizer.delegate = self
    recognizer.cancelsTouchesInView = true
    recognizer.isEnabled = false
    return recognizer
  }()

  private lazy var dragRecognizer: UILongPressGestureRecognizer = {
    let recognizer = UILongPressGestureRecognizer(target: self,
                                                   action: #selector(handleLongPress(_:)))
    recognizer.minimumPressDuration = 0.5
    recognizer.delegate = self
    return recognizer
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = true
    addGestureRecognizer(tapRecognizer)
    addGestureRecognizer(dragRecognizer)
    tapRecognizer.require(toFail: dragRecognizer)
    keyboardObserver = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillChangeFrameNotification,
      object: nil,
      queue: .main) { [weak self] notification in
        self?.keyboardFrameChanged(notification)
      }
    keyboardHideObserver = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillHideNotification,
      object: nil,
      queue: .main) { [weak self] notification in
        self?.keyboardFrameChanged(notification)
      }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
    if let keyboardHideObserver { NotificationCenter.default.removeObserver(keyboardHideObserver) }
  }

  internal func interactionMode() -> InteractionMode {
    switch interactionState {
    case .placing: return .textplacement
    case .editing: return .textediting
    case .dragging, .selected: return .textselected
    case .idle: return owner?.editMode == true ? .draw : .view
    }
  }

  internal func setKeyboardAvoidanceEnabled(_ enabled: Bool) {
    keyboardAvoidanceEnabled = enabled
    updateKeyboardOcclusion()
    if editor != nil { followCaretIfNeeded() }
  }

  func setDefaultFontSize(_ value: Double?) {
    guard let value, value.isFinite, value > 0 else {
      defaultFontSize = defaultTextFontSize
      return
    }
    defaultFontSize = CGFloat(min(max(value, Double(minimumTextFontSize)),
                                  Double(maximumTextFontSize)))
  }

  func setDefaultTextColor(_ value: String?) {
    defaultTextColor = normalizeTextColor(value)
  }

  func setOutlineColor(_ value: String?) {
    outlineColor = parseColor(value ?? "") ?? UIColor(white: 0.25, alpha: 0.75)
    setNeedsDisplay()
  }

  func setSelectedOutlineColor(_ value: String?) {
    selectedOutlineColor = parseColor(value ?? "") ?? UIColor(white: 0.25, alpha: 0.75)
    setNeedsDisplay()
  }

  func setEditorBackgroundColor(_ value: String?) {
    editorBackgroundColor = parseColor(value ?? "")
    if case .editing(let state) = interactionState {
      editor?.backgroundColor = editorFill(for: state.textColor)
    }
  }

  private func editorFill(for textColor: String) -> UIColor {
    let chosen: UIColor
    if let editorBackgroundColor {
      chosen = editorBackgroundColor
    } else {
      let color = parseColor(textColor) ?? .black
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
      chosen = 0.299 * red + 0.587 * green + 0.114 * blue >= 0.5 ? .black : .white
    }
    return chosen.withAlphaComponent(0.9)
  }

  func setSelectedBackgroundColor(_ value: String?) {
    selectedBackgroundColor = parseColor(value ?? "")?.withAlphaComponent(0.14)
    setNeedsDisplay()
  }

  internal func hasPendingPlacement() -> Bool {
    if case .placing = interactionState { return true }
    return false
  }

  func setTextDirection(_ direction: TextDirection) {
    switch direction {
    case .ltr:
      requestedTextDirectionRtl = false
    case .rtl:
      requestedTextDirectionRtl = true
    case .auto:
      requestedTextDirectionRtl = nil
    @unknown default:
      requestedTextDirectionRtl = nil
    }
  }

  internal func armPlacement(generation: UInt64) throws {
    if hasPendingPlacement() { return }
    guard let presentation = presentation() else { throw InkSignView.TextError.notReady }
    guard presentation.generation == generation else { throw InkSignView.TextError.cancelled }
    interactionState = .placing(PlacementState(generation: presentation.generation,
                                               pageIndex: presentation.pageIndex))
    placementTapRecognizer.isEnabled = true
    emitInteractionModeChanged()
    setNeedsDisplay()
  }

  internal func cancelPendingPlacement() {
    if case .placing = interactionState { interactionState = .idle }
    placementTapRecognizer.isEnabled = false
    emitInteractionModeChanged()
    setNeedsDisplay()
  }

  func increaseTextSize() throws -> Double {
    try changeSelectedFont(by: textFontSizeStep)
  }

  func decreaseTextSize() throws -> Double {
    try changeSelectedFont(by: -textFontSizeStep)
  }

  func removeTextAnnotation() throws {
    guard let id = selectedAnnotationID else { throw InkSignView.TextError.notFocused }
    if case .editing(let state) = interactionState, state.original == nil {
      closeEditor()
      clearSelection()
      return
    }
    if case .editing(let state) = interactionState,
       let original = state.original,
       presentation()?.annotations.first(where: { $0.id == original.id }) != original {
      closeEditor()
      clearSelection()
      throw InkSignView.TextError.notFocused
    }
    if case .editing = interactionState { finishEditing() }
    if case .dragging = interactionState { commitDrag() }
    guard let presentation = presentation(),
          let annotation = presentation.annotations.first(where: { $0.id == id }) else {
      throw InkSignView.TextError.notFocused
    }
    owner?.removeTextAnnotation(annotation,
                                generation: presentation.generation,
                                pageIndex: presentation.pageIndex)
    closeEditor()
    clearSelection()
  }

  func finishForLifecycle() {
    if case .placing = interactionState { interactionState = .idle }
    placementTapRecognizer.isEnabled = false
    if editor != nil {
      finishEditing()
    } else if case .dragging = interactionState {
      commitDrag()
    }
    clearSelection()
  }

  func dispose() {
    finishForLifecycle()
    closeEditor()
    onInteractionModeChanged = nil
    owner = nil
  }

  func syncContent() {
    syncPresentation()
  }

  func syncTransform() {
    layoutEditor()
    setNeedsDisplay()
  }

  /// The page overlay owns the coordinate transform; this view only receives
  /// annotation-owned touches and lets the canvas handle all other input.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if let hit = super.hitTest(point, with: event), hit !== self { return hit }
    if hasPendingPlacement() {
      return owner?.canonicalPagePoint(fromOverlay: point) == nil ? nil : self
    }
    if editor != nil || selectedAnnotationID != nil || annotation(at: point) != nil { return self }
    return nil
  }

  /// Routes an editor dismissal before the PDF canvas can observe the touch.
  @discardableResult
  internal func routeTouchBegan(at point: CGPoint) -> Bool {
    if let editor {
      let editorPoint = editor.convert(point, from: self)
      guard !editor.point(inside: editorPoint, with: nil) else { return false }
      finishForLifecycle()
      return true
    }
    return false
  }

  internal func dragTarget(at point: CGPoint) -> String? {
    guard editor == nil, !hasPendingPlacement() else { return nil }
    return annotation(at: point)
  }

  /// Completes the native placement tap after UIKit has ruled out competing
  /// PDF gestures. This point operation keeps the recognizer action
  /// deterministic to exercise without fabricating UITouch instances.
  @discardableResult
  internal func routePlacementTap(at point: CGPoint) -> Bool {
    guard let presentation = presentation(),
          case .placing(let placement) = interactionState,
          placement.generation == presentation.generation,
          placement.pageIndex == presentation.pageIndex,
          let pagePoint = owner?.canonicalPagePoint(fromOverlay: point) else {
      return false
    }
    cancelPendingPlacement()
    placeTextAt(pagePoint, presentation: presentation)
    return true
  }

  override func draw(_ rect: CGRect) {
    guard let transform = owner?.pageToOverlayTransform,
          let owner else { return }
    let pageSize = owner.activePageSize()
    guard pageSize.width > 0, pageSize.height > 0 else { return }
    var annotations = owner.activeTextAnnotations()
    let excludedID = editingID ?? draggingID
    annotations.removeAll { $0.id == excludedID }
    if case .dragging(let drag) = interactionState {
      annotations.append(drag.original.moving(to: drag.position, pageSize: pageSize))
    }
    let selection = selectedAnnotation()
    let shouldDrawSelectedBackground: Bool = {
      switch interactionState {
      case .selected, .dragging: return editor == nil
      default: return false
      }
    }()
    if shouldDrawSelectedBackground, let selection, let selectedBackgroundColor {
      selectedBackgroundColor.setFill()
      UIBezierPath(rect: outlineBounds(for: selection, transform: transform)).fill()
    }
    let context = UIGraphicsGetCurrentContext()
    context?.saveGState()
    context?.concatenate(transform)
    if let context {
      _ = InkSignPdfTextRenderer.drawCanonical(annotations,
                                                pageSize: pageSize,
                                                in: context)
    }
    context?.restoreGState()

    annotations.filter { $0.id != selection?.id }.forEach { annotation in
      let path = UIBezierPath(rect: outlineBounds(for: annotation, transform: transform))
      outlineColor.setStroke()
      path.lineWidth = outlineStrokeWidth
      path.setLineDash([4, 3], count: 2, phase: 0)
      path.stroke()
    }
    if case .editing(let state) = interactionState, editor != nil {
      let text = editor?.text ?? "M"
      let contentSize = editorContentSize(text: text, fontSize: state.fontSize)
      let path = UIBezierPath(rect: CGRect(origin: state.position,
                                            size: contentSize).applying(transform))
      outlineColor.setStroke()
      path.lineWidth = outlineStrokeWidth
      path.setLineDash([4, 3], count: 2, phase: 0)
      path.stroke()
      return
    }
    guard let selection else { return }
    let path = UIBezierPath(rect: outlineBounds(for: selection, transform: transform))
    selectedOutlineColor.setStroke()
    path.lineWidth = outlineStrokeWidth
    path.setLineDash([4, 3], count: 2, phase: 0)
    path.stroke()
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                          shouldReceive touch: UITouch) -> Bool {
    if gestureRecognizer === placementTapRecognizer {
      guard let presentation = presentation(),
            case .placing(let placement) = interactionState,
            placement.generation == presentation.generation,
            placement.pageIndex == presentation.pageIndex else { return false }
      return owner?.canonicalPagePoint(fromOverlay: touch.location(in: self)) != nil
    }
    if hasPendingPlacement() { return false }
    if let editor {
      guard gestureRecognizer === tapRecognizer else { return false }
      let editorPoint = editor.convert(touch.location(in: self), from: self)
      return !editor.point(inside: editorPoint, with: nil)
    }
    if gestureRecognizer === dragRecognizer {
      return dragTarget(at: touch.location(in: self)) != nil
    }
    return true
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                          shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === tapRecognizer || gestureRecognizer === dragRecognizer,
          let overlayView = gestureRecognizer.view,
          let parent = otherGestureRecognizer.view,
          overlayView !== parent else { return false }
    return overlayView.isDescendant(of: parent)
  }

  @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
    let location = recognizer.location(in: self)
    if let editor {
      let editorPoint = editor.convert(location, from: self)
      if editor.point(inside: editorPoint, with: nil) { return }
    }
    if let id = annotation(at: location) {
      selectAndEdit(id)
    } else if selectedAnnotationID != nil {
      finishForLifecycle()
    }
  }

  @objc private func handlePlacementTap(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended,
          hasPendingPlacement() else { return }
    _ = routePlacementTap(at: recognizer.location(in: self))
  }

  @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
    let location = recognizer.location(in: self)
    switch recognizer.state {
    case .began:
      guard let id = dragTarget(at: location) else { return }
      selectForDrag(id, startPoint: location)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    case .changed:
      guard case .dragging(let drag) = interactionState,
            owner?.documentCoordinator.generation == drag.generation,
            owner?.documentCoordinator.document?.activePageIndex == drag.pageIndex,
            let transform = owner?.pageToOverlayTransform,
            let inverse = transform.invertedIfFinite else { return }
      let translation = CGPoint(x: location.x - drag.startPoint.x,
                                y: location.y - drag.startPoint.y)
      let delta = CGPoint(
        x: inverse.a * translation.x + inverse.c * translation.y,
        y: inverse.b * translation.x + inverse.d * translation.y)
      var updated = drag
      updated.position = drag.original.position.applying(
        CGAffineTransform(translationX: delta.x, y: delta.y))
      interactionState = .dragging(updated)
      setNeedsDisplay()
    case .ended:
      commitDrag()
    case .cancelled, .failed:
      if case .dragging(let drag) = interactionState {
        interactionState = owner?.documentCoordinator.generation == drag.generation &&
          owner?.documentCoordinator.document?.activePageIndex == drag.pageIndex
          ? .selected(id: drag.original.id) : .idle
      }
      syncPresentation()
    default:
      break
    }
  }

  private func placeTextAt(
    _ pagePoint: CGPoint,
    presentation: (generation: UInt64, pageIndex: Int,
                   pageSize: CGSize, annotations: [InkSignPdfTextAnnotation])
  ) {
    let id = owner?.allocateTextAnnotationID() ?? ""
    guard !id.isEmpty else { return }
    let size = editorContentSize(text: "M", fontSize: defaultFontSize)
    let isRTL = requestedTextDirectionRtl ?? appDefaultDirectionRtl()
    interactionState = .editing(EditingState(id: id,
                                              generation: presentation.generation,
                                              pageIndex: presentation.pageIndex,
                                              original: nil,
                                              position: pagePoint,
                                              fontSize: defaultFontSize,
                                              isRTL: isRTL,
                                              anchorX: isRTL ? pagePoint.x + size.width : pagePoint.x,
                                              textColor: defaultTextColor))
    showEditor(text: "", centeredAt: pagePoint)
    syncPresentation()
  }

  private func showEditor(text: String, centeredAt pagePoint: CGPoint? = nil) {
    closeEditor()
    guard case .editing(let state) = interactionState else { return }
    let textView = UITextView()
    textView.delegate = self
    textView.backgroundColor = editorFill(for: state.textColor)
    textView.isOpaque = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.isScrollEnabled = false
    textView.textContainerInset = textEditorInsets
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.lineBreakMode = .byClipping
    textView.textContainer.widthTracksTextView = false
    textView.font = UIFont.systemFont(ofSize: state.fontSize)
    textView.textColor = parseColor(state.textColor) ?? .black
    textView.text = text
    textView.overrideUserInterfaceStyle = .light
    editor = textView
    addSubview(textView)
    applyWritingDirection(to: textView, isRTL: state.isRTL)
    layoutEditor()
    if let pagePoint, let pageSize = owner?.documentCoordinator.document?.activePage.geometry.mediaBox.size {
      let contentText = textView.text?.isEmpty == true ? "M" : (textView.text ?? "")
      let contentSize = editorContentSize(text: contentText,
                                          fontSize: state.fontSize)
      let origin = clampedPosition(CGPoint(x: pagePoint.x - contentSize.width / 2,
                                           y: pagePoint.y - contentSize.height / 2),
                                   size: contentSize, pageSize: pageSize)
      var presentationState = state
      presentationState.position = origin
      presentationState.anchorX = presentationState.isRTL
        ? origin.x + contentSize.width : origin.x
      interactionState = .editing(presentationState)
      layoutEditor()
    }
    textView.becomeFirstResponder()
    adoptActiveInputDirectionIfAutomatic(from: textView)
    updateKeyboardOcclusion()
    caretFollowEnabled = true
    followCaretIfNeeded()
    emitInteractionModeChanged()
  }

  func textViewDidChange(_ textView: UITextView) {
    guard textView === editor else { return }
    layoutEditor()
    caretFollowEnabled = true
    followCaretIfNeeded()
    setNeedsDisplay()
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    guard textView === editor else { return }
    if caretFollowEnabled { followCaretIfNeeded() }
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    guard !settlingEditor, textView === editor else { return }
    finishForLifecycle()
  }

  private func selectAndEdit(_ id: String) {
    if editor != nil { finishForLifecycle() }
    guard let presentation = presentation(),
          let annotation = presentation.annotations.first(where: { $0.id == id }) else { return }
    let isRTL = annotation.isRTL
    interactionState = .editing(EditingState(id: id,
                                              generation: presentation.generation,
                                              pageIndex: presentation.pageIndex,
                                              original: annotation,
                                              position: annotation.position,
                                              fontSize: annotation.fontSize,
                                              isRTL: isRTL,
                                              anchorX: isRTL ? annotation.bounds.maxX : annotation.position.x,
                                              textColor: annotation.textColor))
    showEditor(text: annotation.text)
    syncPresentation()
  }

  private func selectForDrag(_ id: String, startPoint: CGPoint) {
    if editor != nil { finishEditing() }
    guard let presentation = presentation(),
          let annotation = presentation.annotations.first(where: { $0.id == id }) else { return }
    interactionState = .dragging(DragState(generation: presentation.generation,
                                            pageIndex: presentation.pageIndex,
                                            original: annotation,
                                            startPoint: startPoint,
                                            position: annotation.position))
    setNeedsDisplay()
    emitInteractionModeChanged()
  }

  private func commitDrag() {
    guard case .dragging(let drag) = interactionState else { return }
    guard let owner,
          owner.documentCoordinator.generation == drag.generation,
          let document = owner.documentCoordinator.document,
          document.activePageIndex == drag.pageIndex else {
      interactionState = .idle
      syncPresentation()
      return
    }
    if drag.position != drag.original.position {
      let updated = drag.original.moving(to: drag.position,
                                         pageSize: document.activePage.geometry.mediaBox.size)
      owner.replaceTextAnnotation(drag.original,
                                  with: updated,
                                  type: .textMove,
                                  generation: drag.generation,
                                  pageIndex: drag.pageIndex)
    }
    interactionState = .selected(id: drag.original.id)
    syncPresentation()
  }

  private func finishEditing() {
    guard case .editing(let state) = interactionState, let textView = editor else { return }
    let text = textView.text ?? ""
    let original = state.original
    var finishedID: String?
    if let original {
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        owner?.removeTextAnnotation(original,
                                    generation: state.generation,
                                    pageIndex: state.pageIndex)
        finishedID = nil
      } else if let pageSize = owner?.activePageSize() {
        let updated = settledAnnotation(state: state, text: text, pageSize: pageSize)
        owner?.replaceTextAnnotation(original,
                                     with: updated,
                                     type: .textEdit,
                                     generation: state.generation,
                                     pageIndex: state.pageIndex)
        finishedID = original.id
      }
    } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let pageSize = owner?.activePageSize() {
      let annotation = settledAnnotation(state: state, text: text, pageSize: pageSize)
        owner?.appendTextAnnotation(annotation,
                                  generation: state.generation,
                                  pageIndex: state.pageIndex)
      finishedID = annotation.id
    }
    closeEditor()
    interactionState = finishedID.map { .selected(id: $0) } ?? .idle
    syncPresentation()
  }

  private func settledAnnotation(state: EditingState, text: String,
                                  pageSize: CGSize) -> InkSignPdfTextAnnotation {
    let size = editorContentSize(text: text, fontSize: state.fontSize)
    let preferred = CGPoint(x: state.isRTL ? state.anchorX - size.width : state.position.x,
                            y: state.position.y)
    let origin = clampedPosition(preferred, size: size, pageSize: pageSize)
    return InkSignPdfTextAnnotation(id: state.id, text: text,
                                    bounds: CGRect(origin: origin, size: size),
                                    fontSize: state.fontSize,
                                    textColor: state.textColor,
                                    isRTL: state.isRTL)
  }

  private func clampedPosition(_ position: CGPoint,
                               size: CGSize,
                               pageSize: CGSize) -> CGPoint {
    let x = size.width >= pageSize.width
      ? (pageSize.width - size.width) / 2
      : min(max(position.x, 0), pageSize.width - size.width)
    let y = size.height >= pageSize.height
      ? (pageSize.height - size.height) / 2
      : min(max(position.y, 0), pageSize.height - size.height)
    return CGPoint(x: x, y: y)
  }

  private func changeSelectedFont(by delta: CGFloat) throws -> Double {
    guard let id = selectedAnnotationID else { throw InkSignView.TextError.notFocused }
    guard presentation() != nil else { throw InkSignView.TextError.notReady }
    if case .editing(let state) = interactionState, state.original == nil {
      let updated = min(max(state.fontSize + delta, minimumTextFontSize), maximumTextFontSize)
      guard updated != state.fontSize else { return Double(updated) }
      var next = state
      next.fontSize = updated
      interactionState = .editing(next)
      editor?.font = UIFont.systemFont(ofSize: updated)
      layoutEditor()
      return Double(updated)
    }
    if case .editing(let state) = interactionState,
       let original = state.original,
       presentation()?.annotations.first(where: { $0.id == original.id }) != original {
      closeEditor()
      clearSelection()
      throw InkSignView.TextError.notFocused
    }
    if editor != nil { finishEditing() }
    guard let presentation = presentation(),
          let annotation = presentation.annotations.first(where: { $0.id == id }) else {
      throw InkSignView.TextError.notFocused
    }
    let fontSize = min(max(annotation.fontSize + delta,
                            minimumTextFontSize), maximumTextFontSize)
    guard fontSize != annotation.fontSize else { return Double(fontSize) }
    let updated = annotation.changingFontSize(to: fontSize, pageSize: presentation.pageSize)
    owner?.replaceTextAnnotation(annotation,
                                 with: updated,
                                 type: .textFont,
                                 generation: presentation.generation,
                                 pageIndex: presentation.pageIndex)
    interactionState = .selected(id: id)
    syncPresentation()
    return Double(fontSize)
  }

  private func closeEditor() {
    guard let editor else { return }
    settlingEditor = true
    editor.resignFirstResponder()
    editor.delegate = nil
    editor.removeFromSuperview()
    self.editor = nil
    settlingEditor = false
    caretFollowEnabled = false
    lastEditorContentSize = .zero
    owner?.resetTextViewportAvoidance()
  }

  private func clearSelection() {
    let hadSelection = selectedAnnotationID != nil || editor != nil
    interactionState = .idle
    if hadSelection { syncPresentation() }
    emitInteractionModeChanged()
  }

  private func syncPresentation() {
    guard let presentation = presentation() else {
      closeEditor()
      interactionState = .idle
      emitInteractionModeChanged()
      return
    }
    if case .placing(let placement) = interactionState,
       placement.generation != presentation.generation ||
       placement.pageIndex != presentation.pageIndex {
      cancelPendingPlacement()
    }
    if case .editing(let state) = interactionState,
       state.generation != presentation.generation || state.pageIndex != presentation.pageIndex {
      finishForLifecycle()
      return
    }
    if let selectedAnnotationID,
       !isUncommittedDraft,
       !presentation.annotations.contains(where: { $0.id == selectedAnnotationID }) {
      interactionState = .idle
    }
    layoutEditor()
    emitInteractionModeChanged()
    setNeedsDisplay()
  }

  private func layoutEditor() {
    guard let editor, case .editing(let state) = interactionState,
          let owner,
          let transform = owner.pageToOverlayTransform else { return }
    let text = editor.text ?? ""
    let contentText = text.isEmpty ? "M" : text
    let contentSize = editorContentSize(text: contentText, fontSize: state.fontSize)
    let editorSize = CGSize(width: contentSize.width + textEditorInsets.left + textEditorInsets.right,
                            height: contentSize.height + textEditorInsets.top + textEditorInsets.bottom)
    let pageSize = owner.activePageSize()
    let positionX = state.isRTL ? state.anchorX - contentSize.width : state.position.x
    var updatedState = state
    updatedState.position.x = contentSize.width >= pageSize.width
      ? (pageSize.width - contentSize.width) / 2
      : min(max(positionX, 0), pageSize.width - contentSize.width)
    updatedState.position.y = contentSize.height >= pageSize.height
      ? (pageSize.height - contentSize.height) / 2
      : min(max(state.position.y, 0), pageSize.height - contentSize.height)
    if updatedState.position != state.position {
      interactionState = .editing(updatedState)
    }
    editor.bounds = CGRect(origin: .zero, size: editorSize)
    editor.textContainer.size = CGSize(width: max(contentSize.width, 1),
                                       height: max(contentSize.height, 1))
    editor.layoutManager.ensureLayout(for: editor.textContainer)
    lastEditorContentSize = contentSize
    editor.center = CGPoint(x: updatedState.position.x + contentSize.width / 2,
                            y: updatedState.position.y + contentSize.height / 2).applying(transform)
    editor.transform = CGAffineTransform(a: transform.a, b: transform.b,
                                         c: transform.c, d: transform.d,
                                         tx: 0, ty: 0)
  }

  private func editorContentSize(text: String, fontSize: CGFloat) -> CGSize {
    InkSignPdfTextRenderer.layout(text: text, fontSize: fontSize).size
  }

  private func followCaretIfNeeded() {
    guard let editor,
          let range = editor.selectedTextRange else { return }
    let caret = editor.caretRect(for: range.end).insetBy(dx: -2, dy: -2)
    let caretInContainer = convert(caret, from: editor)
    owner?.ensureTextVisible(caretInContainer, padding: 8)
  }

  private func keyboardFrameChanged(_ notification: Notification) {
    if notification.name == UIResponder.keyboardWillHideNotification {
      keyboardFrameInScreen = nil
    } else if let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
      keyboardFrameInScreen = frameValue.cgRectValue
    }
    updateKeyboardOcclusion()
    if editor != nil { followCaretIfNeeded() }
  }

  private func updateKeyboardOcclusion() {
    guard keyboardAvoidanceEnabled, editor != nil,
          let frame = keyboardFrameInScreen,
          let window else {
      owner?.resetTextViewportAvoidance()
      return
    }
    let keyboardFrame = convert(window.convert(frame, from: nil), from: window)
    owner?.setTextKeyboardOcclusion(max(0, bounds.maxY - keyboardFrame.minY))
  }

  private func appDefaultDirectionRtl() -> Bool {
    if let localeLanguage = Locale.current.languageCode?.lowercased() {
      return localeLanguage == "ar" || localeLanguage == "he" ||
        localeLanguage == "fa" || localeLanguage == "ur"
    }
    return false
  }

  private func adoptActiveInputDirectionIfAutomatic(from textView: UITextView) {
    guard requestedTextDirectionRtl == nil,
          case .editing(var state) = interactionState,
          state.original == nil,
          let isRTL = inputLanguageDirectionHint(textView.textInputMode?.primaryLanguage),
          state.isRTL != isRTL else { return }
    state.isRTL = isRTL
    let currentSize = editorContentSize(text: textView.text.isEmpty ? "M" : textView.text,
                                        fontSize: state.fontSize)
    state.anchorX = isRTL ? state.position.x + currentSize.width : state.position.x
    interactionState = .editing(state)
    applyWritingDirection(to: textView, isRTL: isRTL)
    layoutEditor()
  }

  private func applyWritingDirection(to textView: UITextView, isRTL: Bool) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    let textRange = NSRange(location: 0, length: textView.textStorage.length)
    if textRange.length > 0 {
      textView.textStorage.addAttribute(.paragraphStyle,
                                        value: paragraphStyle,
                                        range: textRange)
    }
    textView.typingAttributes[.paragraphStyle] = paragraphStyle
    textView.textAlignment = isRTL ? .right : .left
    textView.semanticContentAttribute = isRTL ? .forceRightToLeft : .forceLeftToRight
  }

  private func inputLanguageDirectionHint(_ languageTag: String?) -> Bool? {
    guard let language = languageTag?.lowercased(), !language.isEmpty else { return nil }
    if ["ar", "he", "fa", "ur"].contains(where: { language.hasPrefix($0) }) { return true }
    return false
  }

  private func selectedAnnotation() -> InkSignPdfTextAnnotation? {
    if case .dragging(let drag) = interactionState,
       let pageSize = owner?.activePageSize() {
      return drag.original.moving(to: drag.position, pageSize: pageSize)
    }
    guard let selectedAnnotationID else { return nil }
    return owner?.activeTextAnnotations().first(where: { $0.id == selectedAnnotationID })
  }

  private func annotation(at point: CGPoint) -> String? {
    guard let transform = owner?.pageToOverlayTransform,
          let inverse = transform.invertedIfFinite else { return nil }
    let pagePoint = point.applying(inverse)
    let scale = max(hypot(transform.a, transform.b), 0.001)
    let halfHitSize = 20 / scale
    return owner?.activeTextAnnotations().reversed().first(where: { annotation in
      let hitBounds = annotation.bounds.insetBy(dx: -max(halfHitSize - annotation.bounds.width / 2, 0),
                                                dy: -max(halfHitSize - annotation.bounds.height / 2, 0))
      let visibleBounds = outlineBounds(for: annotation, transform: transform)
        .insetBy(dx: -outlineStrokeWidth / 2, dy: -outlineStrokeWidth / 2)
      return hitBounds.contains(pagePoint) || visibleBounds.contains(point)
    })?.id
  }

  private func outlineBounds(for annotation: InkSignPdfTextAnnotation,
                             transform: CGAffineTransform) -> CGRect {
    let inset = annotation.fontSize * hypot(transform.a, transform.b) * 0.25
    return annotation.bounds.applying(transform).insetBy(dx: -inset, dy: -inset)
  }

  private func presentation() -> (generation: UInt64, pageIndex: Int,
                                  pageSize: CGSize, annotations: [InkSignPdfTextAnnotation])? {
    guard let owner, let state = owner.documentCoordinator.document,
          owner.attachedOverlayPage == state.activePage.id,
          owner.pageToOverlayTransform != nil else { return nil }
    return (owner.documentCoordinator.generation, state.activePageIndex,
            state.activePage.geometry.mediaBox.size,
            state.activePage.history.content.textAnnotations)
  }

  private var selectedAnnotationID: String? {
    switch interactionState {
    case .idle, .placing: return nil
    case .editing(let state): return state.id
    case .dragging(let state): return state.original.id
    case .selected(let id): return id
    }
  }

  private var editingID: String? {
    guard case .editing(let state) = interactionState else { return nil }
    return state.id
  }

  private var isUncommittedDraft: Bool {
    guard case .editing(let state) = interactionState else { return false }
    return editor != nil && state.original == nil
  }

  private var draggingID: String? {
    guard case .dragging(let state) = interactionState else { return nil }
    return state.original.id
  }

  private func emitInteractionModeChanged() {
    onInteractionModeChanged?()
  }
}

extension CGAffineTransform {
  var invertedIfFinite: CGAffineTransform? {
    let determinant = a * d - b * c
    guard determinant.isFinite, abs(determinant) > 0.000001,
          a.isFinite, b.isFinite, c.isFinite, d.isFinite,
          tx.isFinite, ty.isFinite else { return nil }
    let result = inverted()
    guard result.a.isFinite, result.b.isFinite, result.c.isFinite,
          result.d.isFinite, result.tx.isFinite, result.ty.isFinite else { return nil }
    return result
  }
}
