import CoreGraphics
import UIKit

private let defaultTextFontSize: CGFloat = 16
private let minimumTextFontSize: CGFloat = 8
private let maximumTextFontSize: CGFloat = 72
private let textFontSizeStep: CGFloat = 1
private let textEditorInsets = InkSignPdfTextStyle.presentationInsets

struct InkSignPdfTextDirectionState: Equatable {
  enum Request: Equatable {
    case automatic
    case fixed(Bool)
  }

  let request: Request
  private(set) var effectiveRTL: Bool
  private(set) var isLocked: Bool

  static func writingDirectionHint(for languageTag: String?) -> Bool? {
    guard let languageTag, !languageTag.isEmpty else { return nil }
    let direction: Locale.LanguageDirection
    if #available(iOS 16.0, *) {
      direction = Locale.Language(identifier: languageTag).characterDirection
    } else {
      direction = Locale.characterDirection(forLanguage: languageTag)
    }
    switch direction {
    case .rightToLeft: return true
    case .leftToRight, .topToBottom, .bottomToTop: return false
    case .unknown: return nil
    @unknown default: return nil
    }
  }

  init(request: Request, fallbackRTL: Bool) {
    self.request = request
    switch request {
    case .automatic:
      effectiveRTL = fallbackRTL
      isLocked = false
    case .fixed(let isRTL):
      effectiveRTL = isRTL
      isLocked = true
    }
  }

  @discardableResult
  mutating func adoptInputDirectionWhileEmpty(_ inputRTL: Bool?) -> Bool {
    guard case .automatic = request, !isLocked, let inputRTL else { return false }
    return setEffectiveDirection(inputRTL)
  }

  @discardableResult
  mutating func lockForContent(_ inputRTL: Bool?) -> Bool {
    guard case .automatic = request, !isLocked else { return false }
    let changed = adoptInputDirectionWhileEmpty(inputRTL)
    isLocked = true
    return changed
  }

  @discardableResult
  mutating func reopenEmptyEditor(_ inputRTL: Bool?) -> Bool {
    guard case .automatic = request else { return false }
    isLocked = false
    return adoptInputDirectionWhileEmpty(inputRTL)
  }

  private mutating func setEffectiveDirection(_ isRTL: Bool) -> Bool {
    guard effectiveRTL != isRTL else { return false }
    effectiveRTL = isRTL
    return true
  }
}

enum InkSignPdfTextDragPhase: Equatable {
  case began
  case changed
  case ended
  case cancelled
}

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
    var direction: InkSignPdfTextDirectionState
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
  private var keyboardScreen: UIScreen?
  private var keyboardObserver: NSObjectProtocol?
  private var keyboardHideObserver: NSObjectProtocol?
  private var inputModeObserver: NSObjectProtocol?
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

  private lazy var selectedDragRecognizer: UIPanGestureRecognizer = {
    let recognizer = UIPanGestureRecognizer(target: self,
                                           action: #selector(handleSelectedDrag(_:)))
    recognizer.minimumNumberOfTouches = 1
    recognizer.maximumNumberOfTouches = 1
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
    addGestureRecognizer(selectedDragRecognizer)
    tapRecognizer.require(toFail: dragRecognizer)
    tapRecognizer.require(toFail: selectedDragRecognizer)
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
    if let inputModeObserver { NotificationCenter.default.removeObserver(inputModeObserver) }
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

  private func defaultWritingDirectionIsRTL() -> Bool {
    if #available(iOS 16.0, *) {
      return Locale.current.language.characterDirection == .rightToLeft
    }
    guard let languageCode = Locale.current.languageCode else { return false }
    return InkSignPdfTextDirectionState.writingDirectionHint(for: languageCode) ?? false
  }

  private func inputLanguageWritingDirectionHint(_ languageTag: String?) -> Bool? {
    InkSignPdfTextDirectionState.writingDirectionHint(for: languageTag)
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
    if editor != nil || annotation(at: point) != nil { return self }
    return nil
  }

  internal func dragTarget(at point: CGPoint) -> String? {
    guard editor == nil, !hasPendingPlacement() else { return nil }
    return annotation(at: point)
  }

  @discardableResult
  internal func routeTap(at location: CGPoint) -> Bool {
    if let editor {
      let editorPoint = editor.convert(location, from: self)
      guard !editor.point(inside: editorPoint, with: nil) else { return false }
      finishForLifecycle()
    }
    if let id = annotation(at: location) {
      selectAndEdit(id)
      return true
    }
    if selectedAnnotationID != nil { finishForLifecycle() }
    return false
  }

  @discardableResult
  internal func routeDrag(_ phase: InkSignPdfTextDragPhase,
                          at location: CGPoint,
                          selectedOnly: Bool) -> Bool {
    switch phase {
    case .began:
      guard let id = dragTarget(at: location),
            selectedOnly ? id == selectedAnnotationID : id != selectedAnnotationID else {
        return false
      }
      return selectForDrag(id, startPoint: location)
    case .changed:
      return updateDrag(to: location)
    case .ended:
      guard case .dragging = interactionState else { return false }
      commitDrag()
      return true
    case .cancelled:
      guard case .dragging = interactionState else { return false }
      cancelDrag()
      return true
    }
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
      guard let editor else { return }
      let path = UIBezierPath(rect: editor.frame)
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
    if gestureRecognizer === tapRecognizer {
      return annotation(at: touch.location(in: self)) != nil
    }
    if gestureRecognizer === dragRecognizer {
      guard let target = dragTarget(at: touch.location(in: self)) else { return false }
      return target != selectedAnnotationID
    }
    if gestureRecognizer === selectedDragRecognizer {
      guard let selectedAnnotationID else { return false }
      return dragTarget(at: touch.location(in: self)) == selectedAnnotationID
    }
    return true
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    guard isTextInputGesture(gestureRecognizer),
          !isTextInputGesture(otherGestureRecognizer),
          otherGestureRecognizer !== placementTapRecognizer,
          let owner,
          otherGestureRecognizer !== owner.doubleTapGestureRecognizer,
          isPDFViewGesture(otherGestureRecognizer) else { return false }
    return true
  }

  private func isTextInputGesture(_ recognizer: UIGestureRecognizer) -> Bool {
    recognizer === tapRecognizer || recognizer === dragRecognizer ||
      recognizer === selectedDragRecognizer
  }

  private func isPDFViewGesture(_ recognizer: UIGestureRecognizer) -> Bool {
    guard let owner,
          let pdfView = owner.documentView,
          var view = recognizer.view else { return false }
    while view !== pdfView {
      if view is InkSignPdfPageOverlayView || view === owner.textInteractionOverlay {
        return false
      }
      guard let superview = view.superview else { return false }
      view = superview
    }
    return true
  }

  @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
    _ = routeTap(at: recognizer.location(in: self))
  }

  @objc private func handlePlacementTap(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended,
          hasPendingPlacement() else { return }
    _ = routePlacementTap(at: recognizer.location(in: self))
  }

  @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
    guard let phase = dragPhase(for: recognizer.state) else { return }
    let began = phase == .began
    guard routeDrag(phase, at: recognizer.location(in: self), selectedOnly: false) else { return }
    if began { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
  }

  @objc private func handleSelectedDrag(_ recognizer: UIPanGestureRecognizer) {
    guard let phase = dragPhase(for: recognizer.state) else { return }
    let location = recognizer.location(in: self)
    if phase == .began {
      let translation = recognizer.translation(in: self)
      let start = CGPoint(x: location.x - translation.x,
                          y: location.y - translation.y)
      guard routeDrag(.began, at: start, selectedOnly: true) else { return }
      _ = routeDrag(.changed, at: location, selectedOnly: true)
      return
    }
    _ = routeDrag(phase, at: location, selectedOnly: true)
  }

  private func dragPhase(for state: UIGestureRecognizer.State) -> InkSignPdfTextDragPhase? {
    switch state {
    case .began:
      return .began
    case .changed: return .changed
    case .ended: return .ended
    case .cancelled, .failed: return .cancelled
    default:
      return nil
    }
  }

  private func placeTextAt(
    _ pagePoint: CGPoint,
    presentation: (generation: UInt64, pageIndex: Int,
                   pageSize: CGSize, annotations: [InkSignPdfTextAnnotation])
  ) {
    let id = owner?.allocateTextAnnotationID() ?? ""
    guard !id.isEmpty else { return }
    let direction = InkSignPdfTextDirectionState(
      request: requestedTextDirectionRtl.map {
        InkSignPdfTextDirectionState.Request.fixed($0)
      } ?? .automatic,
      fallbackRTL: defaultWritingDirectionIsRTL())
    interactionState = .editing(EditingState(id: id,
                                              generation: presentation.generation,
                                              pageIndex: presentation.pageIndex,
                                              original: nil,
                                              position: pagePoint,
                                              fontSize: defaultFontSize,
                                              direction: direction,
                                              anchorX: pagePoint.x,
                                              textColor: defaultTextColor))
    showEditor(text: "", placementAnchor: pagePoint)
    syncPresentation()
  }

  private func showEditor(text: String, placementAnchor: CGPoint? = nil) {
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
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.textContainer.widthTracksTextView = false
    textView.text = text
    textView.overrideUserInterfaceStyle = .light
    editor = textView
    addSubview(textView)
    applyTextStyle(to: textView, state: state)
    layoutEditor()
    if let placementAnchor, let pageSize = owner?.activePageSize() {
      var presentationState = state
      let frame = InkSignPdfTextBoxGeometry.initialFrame(
        caretAnchor: placementAnchor,
        size: lastEditorContentSize,
        isRTL: presentationState.direction.effectiveRTL,
        insets: textEditorInsets,
        pageSize: pageSize)
      presentationState.position = frame.origin
      presentationState.anchorX = InkSignPdfTextBoxGeometry.contentCaretAnchor(
        in: frame,
        isRTL: presentationState.direction.effectiveRTL,
        insets: textEditorInsets).x
      interactionState = .editing(presentationState)
      layoutEditor()
    }
    observeInputModeChangesIfNeeded(for: state)
    textView.becomeFirstResponder()
    updateDirection(in: textView,
                    languageTag: textView.textInputMode?.primaryLanguage,
                    contentIsEmpty: true)
    updateKeyboardOcclusion()
    caretFollowEnabled = true
    followCaretIfNeeded()
    emitInteractionModeChanged()
  }

  func textViewDidChange(_ textView: UITextView) {
    guard textView === editor else { return }
    let contentIsEmpty = textView.text.isEmpty
    updateDirection(in: textView,
                    languageTag: textView.textInputMode?.primaryLanguage,
                    contentIsEmpty: contentIsEmpty,
                    reopening: contentIsEmpty)
    layoutEditor()
    caretFollowEnabled = true
    followCaretIfNeeded()
    setNeedsDisplay()
  }

  func textView(_ textView: UITextView,
                shouldChangeTextIn range: NSRange,
                replacementText text: String) -> Bool {
    guard textView === editor,
          case .editing(let state) = interactionState,
          state.original == nil,
          state.direction.request == .automatic,
          !state.direction.isLocked else { return true }
    let updatedText = (textView.text as NSString).replacingCharacters(in: range, with: text)
    if !updatedText.isEmpty {
      updateDirection(in: textView,
                      languageTag: textView.textInputMode?.primaryLanguage,
                      contentIsEmpty: false)
    }
    return true
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
    let direction = InkSignPdfTextDirectionState(request: .fixed(annotation.isRTL),
                                                  fallbackRTL: annotation.isRTL)
    interactionState = .editing(EditingState(id: id,
                                              generation: presentation.generation,
                                              pageIndex: presentation.pageIndex,
                                              original: annotation,
                                              position: annotation.position,
                                              fontSize: annotation.fontSize,
                                              direction: direction,
                                              anchorX: InkSignPdfTextBoxGeometry.contentCaretAnchor(
                                                in: annotation.bounds,
                                                isRTL: annotation.isRTL,
                                                insets: textEditorInsets).x,
                                              textColor: annotation.textColor))
    showEditor(text: annotation.text)
    syncPresentation()
  }

  private func selectForDrag(_ id: String, startPoint: CGPoint) -> Bool {
    if editor != nil { finishEditing() }
    guard let presentation = presentation(),
          let annotation = presentation.annotations.first(where: { $0.id == id }) else { return false }
    interactionState = .dragging(DragState(generation: presentation.generation,
                                            pageIndex: presentation.pageIndex,
                                            original: annotation,
                                            startPoint: startPoint,
                                            position: annotation.position))
    setNeedsDisplay()
    emitInteractionModeChanged()
    return true
  }

  private func updateDrag(to location: CGPoint) -> Bool {
    guard case .dragging(let drag) = interactionState else { return false }
    guard let owner,
          owner.documentCoordinator.generation == drag.generation,
          owner.documentCoordinator.document?.activePageIndex == drag.pageIndex,
          let transform = owner.pageToOverlayTransform,
          let inverse = transform.invertedIfFinite else {
      cancelDrag()
      return false
    }
    let translation = CGPoint(x: location.x - drag.startPoint.x,
                              y: location.y - drag.startPoint.y)
    let delta = CGPoint(x: inverse.a * translation.x + inverse.c * translation.y,
                        y: inverse.b * translation.x + inverse.d * translation.y)
    var updated = drag
    updated.position = drag.original.position.applying(
      CGAffineTransform(translationX: delta.x, y: delta.y))
    interactionState = .dragging(updated)
    setNeedsDisplay()
    return true
  }

  private func cancelDrag() {
    guard case .dragging(let drag) = interactionState else { return }
    interactionState = owner?.documentCoordinator.generation == drag.generation &&
      owner?.documentCoordinator.document?.activePageIndex == drag.pageIndex
      ? .selected(id: drag.original.id) : .idle
    syncPresentation()
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
    guard case .editing = interactionState, let textView = editor else { return }
    layoutEditor()
    guard case .editing(let state) = interactionState else { return }
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
    let size = lastEditorContentSize
    let preferred = CGPoint(x: state.direction.effectiveRTL
      ? state.anchorX + textEditorInsets.right - size.width
      : state.anchorX - textEditorInsets.left,
                            y: state.position.y)
    let origin = InkSignPdfTextBoxGeometry.clampedOrigin(for: size,
                                                        preferred: preferred,
                                                        pageSize: pageSize)
    return InkSignPdfTextAnnotation(id: state.id, text: text,
                                    bounds: CGRect(origin: origin, size: size),
                                    fontSize: state.fontSize,
                                    textColor: state.textColor,
                                    isRTL: state.direction.effectiveRTL)
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
      if let editor { applyTextStyle(to: editor, state: next) }
      layoutEditor()
      setNeedsDisplay()
      followCaretIfNeeded()
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
    if let inputModeObserver {
      NotificationCenter.default.removeObserver(inputModeObserver)
      self.inputModeObserver = nil
    }
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
    let pageSize = owner.activePageSize()
    let editorSize = measureEditor(editor, maximumWidth: pageSize.width)
    let positionX = state.direction.effectiveRTL
      ? state.anchorX + textEditorInsets.right - editorSize.width
      : state.anchorX - textEditorInsets.left
    let preferred = CGPoint(x: positionX, y: state.position.y)
    let origin = InkSignPdfTextBoxGeometry.clampedOrigin(for: editorSize,
                                                        preferred: preferred,
                                                        pageSize: pageSize)
    var updatedState = state
    updatedState.position = origin
    if origin.x != positionX {
      updatedState.anchorX = InkSignPdfTextBoxGeometry.contentCaretAnchor(
        in: CGRect(origin: origin, size: editorSize),
        isRTL: state.direction.effectiveRTL,
        insets: textEditorInsets).x
    }
    if updatedState.position != state.position || updatedState.anchorX != state.anchorX {
      interactionState = .editing(updatedState)
    }
    editor.bounds = CGRect(origin: .zero, size: editorSize)
    editor.layoutManager.ensureLayout(for: editor.textContainer)
    editor.layoutIfNeeded()
    lastEditorContentSize = editorSize
    editor.center = CGPoint(x: updatedState.position.x + editorSize.width / 2,
                            y: updatedState.position.y + editorSize.height / 2).applying(transform)
    editor.transform = CGAffineTransform(a: transform.a, b: transform.b,
                                         c: transform.c, d: transform.d,
                                         tx: 0, ty: 0)
  }

  private func measureEditor(_ editor: UITextView, maximumWidth: CGFloat) -> CGSize {
    let insets = textEditorInsets
    let availableWidth = max(1, maximumWidth - insets.left - insets.right)
    let font = editor.font ?? InkSignPdfTextStyle.font(size: defaultFontSize)
    func layout(at contentWidth: CGFloat) -> CGSize {
      editor.textContainer.size = CGSize(width: contentWidth,
                                         height: .greatestFiniteMagnitude)
      editor.bounds.size = CGSize(width: contentWidth + insets.left + insets.right,
                                  height: max(editor.bounds.height, font.lineHeight))
      editor.setContentOffset(.zero, animated: false)
      editor.layoutManager.ensureLayout(for: editor.textContainer)
      editor.layoutIfNeeded()
      return layoutExtent(editor, insets: insets)
    }

    let availableLayout = layout(at: availableWidth)
    var contentWidth = editor.text.isEmpty
      ? min(availableWidth, font.pointSize)
      : min(availableWidth, availableLayout.width)
    var finalLayout = layout(at: contentWidth)
    if contentWidth < availableWidth, finalLayout.width > contentWidth {
      contentWidth = min(availableWidth, finalLayout.width)
      finalLayout = layout(at: contentWidth)
    }

    let size = CGSize(width: contentWidth + insets.left + insets.right,
                      height: max(finalLayout.height, font.lineHeight) +
                        insets.top + insets.bottom)
    editor.bounds.size = size
    editor.setContentOffset(.zero, animated: false)
    editor.layoutManager.ensureLayout(for: editor.textContainer)
    editor.layoutIfNeeded()
    return size
  }

  private func layoutExtent(_ editor: UITextView, insets: UIEdgeInsets) -> CGSize {
    let glyphBounds = editor.layoutManager.usedRect(for: editor.textContainer)
    let caretInView = editor.selectedTextRange.map { editor.caretRect(for: $0.end) } ?? .null
    let caretInContainer = caretInView.offsetBy(
      dx: editor.contentOffset.x - insets.left,
      dy: editor.contentOffset.y - insets.top)
    let textAndCaretBounds = glyphBounds.union(caretInContainer)
    return CGSize(width: max(textAndCaretBounds.width, 0),
                  height: max(textAndCaretBounds.maxY, 0))
  }

  private func applyTextStyle(to textView: UITextView, state: EditingState) {
    InkSignPdfTextStyle.apply(to: textView,
                              fontSize: state.fontSize,
                              color: parseColor(state.textColor) ?? .black,
                              isRTL: state.direction.effectiveRTL)
  }

  private func followCaretIfNeeded() {
    guard let editor, let owner,
          let range = editor.selectedTextRange else { return }
    let outlineInOverlay = editor.convert(editor.bounds, to: self)
      .insetBy(dx: -outlineStrokeWidth / 2, dy: -outlineStrokeWidth / 2)
    let outline = convert(outlineInOverlay, to: owner.container)
    let caret = editor.convert(editor.caretRect(for: range.end), to: owner.container)
    owner.ensureTextVisible(outline: outline, caret: caret)
  }

  private func keyboardFrameChanged(_ notification: Notification) {
    if notification.name == UIResponder.keyboardWillHideNotification {
      keyboardFrameInScreen = nil
      keyboardScreen = nil
    } else if let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
      keyboardFrameInScreen = frameValue.cgRectValue
      keyboardScreen = notification.object as? UIScreen
    }
    updateKeyboardOcclusion()
    if editor != nil { followCaretIfNeeded() }
  }

  private func updateKeyboardOcclusion() {
    guard keyboardAvoidanceEnabled, editor != nil,
          let frame = keyboardFrameInScreen,
          let window,
          let owner else {
      owner?.resetTextViewportAvoidance()
      return
    }
    let keyboardFrame = (keyboardScreen ?? window.screen).coordinateSpace.convert(
      frame, to: owner.container)
    let overlap = owner.container.bounds.intersection(keyboardFrame)
    owner.setTextKeyboardOcclusion(overlap.isNull
      ? 0 : max(0, owner.container.bounds.maxY - overlap.minY))
  }

  private func observeInputModeChangesIfNeeded(for state: EditingState) {
    guard state.original == nil,
          state.direction.request == .automatic,
          inputModeObserver == nil else { return }
    inputModeObserver = NotificationCenter.default.addObserver(
      forName: UITextInputMode.currentInputModeDidChangeNotification,
      object: nil,
      queue: .main) { [weak self] notification in
        guard let self, let editor = self.editor, editor.text.isEmpty else { return }
        let inputMode = notification.object as? UITextInputMode
        self.updateDirection(in: editor,
                             languageTag: inputMode?.primaryLanguage,
                             contentIsEmpty: true)
        self.followCaretIfNeeded()
      }
  }

  private func updateDirection(in textView: UITextView,
                               languageTag: String?,
                               contentIsEmpty: Bool,
                               reopening: Bool = false) {
    guard textView === editor,
          case .editing(var state) = interactionState,
          state.original == nil else { return }
    let previousDirection = state.direction.effectiveRTL
    let inputRTL = inputLanguageWritingDirectionHint(languageTag)
    if contentIsEmpty {
      if reopening {
        state.direction.reopenEmptyEditor(inputRTL)
      } else {
        state.direction.adoptInputDirectionWhileEmpty(inputRTL)
      }
    } else {
      state.direction.lockForContent(inputRTL)
    }
    interactionState = .editing(state)
    guard state.direction.effectiveRTL != previousDirection else { return }
    applyTextStyle(to: textView, state: state)
    layoutEditor()
    setNeedsDisplay()
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
    InkSignPdfTextBoxGeometry.outlineBounds(for: annotation.bounds, transform: transform)
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
