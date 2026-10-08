import CoreGraphics
import UIKit

private let defaultTextFontSize: CGFloat = 16
private let minimumTextFontSize: CGFloat = 8
private let maximumTextFontSize: CGFloat = 72
private let textFontSizeStep: CGFloat = 1
private let placementRuleSnapTolerance: CGFloat = 24
private let textEditorInsets = InkSignPdfTextStyle.presentationInsets

private final class InkSignPdfTextEditorView: UITextView {
  var admitsInput: ((NSRange, String) -> Bool)?

  override func insertText(_ text: String) {
    guard admitsInput?(selectedRange, text) ?? true else { return }
    super.insertText(text)
  }

  override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    guard admitsInput?(markedTextReplacementRange, markedText ?? "") ?? true else { return }
    super.setMarkedText(markedText, selectedRange: selectedRange)
  }

  private var markedTextReplacementRange: NSRange {
    guard let markedTextRange else { return selectedRange }
    let location = offset(from: beginningOfDocument, to: markedTextRange.start)
    let length = offset(from: markedTextRange.start, to: markedTextRange.end)
    return NSRange(location: location, length: length)
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
    let id: UInt64
    let generation: UInt64
    let pageIndex: Int
    let original: InkSignPdfTextAnnotation?
    let layoutRotation: Int
    var position: CGPoint
    var placementAnchor: InkSignPdfTextBoxGeometry.PlacementAnchor?
    var fontSize: CGFloat
    var isRTL: Bool
    var textColor: String
    var flowBounds: CGRect?
    var maxLines: Int
    var verticalAnchor: InkSignPdfTextVerticalAnchor
    var alignment: InkSignPdfTextAlignment
  }

  private struct InitialPlacement {
    let tap: CGPoint
    let rule: InkSignPdfPlacementRule?
  }

  private struct PlacementState {
    let generation: UInt64
    let pageIndex: Int
    var isRTL: Bool
    let options: TextModeOptions?
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
    case selected(id: UInt64)
  }

  weak var owner: InkSignView?
  private var defaultFontSize = defaultTextFontSize
  private var defaultTextColor = "#000000"
  private var requestedTextDirectionRtl: Bool?
  private var outlineColor = UIColor(white: 0.25, alpha: 0.75)
  private var selectedOutlineColor = UIColor(white: 0.25, alpha: 0.75)
  private var editorBackgroundColor: UIColor?
  private var selectedBackgroundColor: UIColor?
  private var interactionState: InteractionState = .idle {
    didSet {
      let wasPlacing: Bool
      if case .placing = oldValue { wasPlacing = true } else { wasPlacing = false }
      let isPlacing: Bool
      if case .placing = interactionState { isPlacing = true } else { isPlacing = false }
      if wasPlacing != isPlacing { placementTapRecognizer.isEnabled = isPlacing }
      let selection = selectedAnnotationID.flatMap { id -> TextSelection? in
        guard let owner, let document = owner.documentCoordinator.document,
              document.pages.indices.contains(document.activePageIndex) else { return nil }
        return TextSelection(textId: Double(id), pageId: document.activePage.id.uuidString)
      }
      let identity = selection.map { "\($0.textId):\($0.pageId)" }
      if identity != lastEmittedSelectionIdentity {
        lastEmittedSelectionIdentity = identity
        onTextSelectionChange?(selection)
      }
    }
  }
  private var editor: UITextView?
  private var settlingEditor = false
  private var lastEditorContentSize = CGSize.zero
  private var keyboardAvoidanceEnabled = true
  private var caretFollowEnabled = false
  private var keyboardFrameInScreen: CGRect?
  private var keyboardScreen: UIScreen?
  private var keyboardObserver: NSObjectProtocol?
  private var keyboardHideObserver: NSObjectProtocol?
  private enum PlacementRuleCache {
    case scanning(generation: UInt64, pageID: UUID, requestID: UInt64)
    case ready(generation: UInt64, pageID: UUID, rules: [InkSignPdfPlacementRule], labels: [InkSignPdfKeyTextMatch])

    func matches(generation: UInt64, pageID: UUID) -> Bool {
      switch self {
      case .scanning(let cachedGeneration, let cachedPageID, _),
           .ready(let cachedGeneration, let cachedPageID, _, _):
        return cachedGeneration == generation && cachedPageID == pageID
      }
    }
  }
  private var placementRuleCache: PlacementRuleCache?
  private var placementRuleRequestID: UInt64 = 0
  private let outlineStrokeWidth: CGFloat = 2

  var onInteractionModeChanged: (() -> Void)?
  var onTextSelectionChange: ((TextSelection?) -> Void)?
  private var lastEmittedSelectionIdentity: String?

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
  }

  internal func interactionMode() -> InteractionMode {
    switch interactionState {
    case .placing: return .textadd
    case .editing: return .textedit
    case .dragging, .selected: return .view
    case .idle: return owner?.editMode == true ? .ink : .view
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

  func setTextDirection(direction: TextDirection) {
    let isRTL: Bool?
    switch direction {
    case .ltr:
      isRTL = false
    case .rtl:
      isRTL = true
    case .auto:
      isRTL = nil
    }
    requestedTextDirectionRtl = isRTL
    let resolvedDirection = isRTL ?? appLayoutIsRTL()
    switch interactionState {
    case .placing:
      break
    case .editing(var state):
      guard state.isRTL != resolvedDirection else { return }
      // Keep the box origin through the direction change. Its new width may
      // differ after TextKit applies the paragraph direction.
      if state.flowBounds == nil { state.placementAnchor = nil }
      state.isRTL = resolvedDirection
      interactionState = .editing(state)
      guard let editor else { return }
      let selection = editor.selectedRange
      applyTextStyle(to: editor, state: state)
      editor.selectedRange = selection
      layoutEditor()
      if state.flowBounds == nil,
         case .editing(var positioned) = interactionState {
        positioned.placementAnchor = InkSignPdfTextBoxGeometry.PlacementAnchor(
          x: resolvedDirection
            ? positioned.position.x + editor.bounds.width
            : positioned.position.x,
          y: positioned.position.y,
          horizontal: resolvedDirection ? .right : .left,
          vertical: .top)
        interactionState = .editing(positioned)
      }
      followCaretIfNeeded()
      setNeedsDisplay()
    case .idle, .dragging, .selected:
      break
    }
  }

  func addTextAnnotation(text: String,
                         bounds: TextAnnotationBounds,
                         options: TextAnnotationOptions?,
                         resolvedDirectionRtl: Bool? = nil,
                         requireVisibleLine: Bool = false,
                         capturedPage: (generation: UInt64, pageID: UUID,
                                        pageSize: CGSize, layoutRotation: Int)? = nil,
                         targetID: UInt64? = nil) throws {
    guard let owner else { throw InkSignView.TextError.notReady }
    let context: (generation: UInt64, pageIndex: Int?, pageID: UUID?)
    if let capturedPage {
      context = (capturedPage.generation, nil, capturedPage.pageID)
    } else if let presentation = presentation() {
      context = (presentation.generation, presentation.pageIndex, nil)
    } else {
      throw InkSignView.TextError.notReady
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InkSignView.TextError.invalidText
    }
    let isRTL = resolvedDirectionRtl ?? resolvedDirection(options?.direction)
    let layoutRotation: Int
    let pageSize: CGSize
    if let capturedPage {
      layoutRotation = capturedPage.layoutRotation
      pageSize = capturedPage.pageSize
    } else if let page = owner.documentCoordinator.document?.activePage {
      layoutRotation = page.geometry.rotation
      pageSize = page.geometry.displaySize
    } else {
      throw InkSignView.TextError.notReady
    }
    guard let flowBounds = makeFlowBounds(bounds: bounds, pageSize: pageSize) else {
      throw InkSignView.TextError.invalidBounds
    }
    let verticalAnchor = InkSignPdfTextVerticalAnchor(options?.verticalAnchor)
    let alignment = InkSignPdfTextAlignment(options?.alignment)
    let maxLines = lineLimit(options?.maxLines)
    let fontSize = CGFloat(options?.fontSize ?? Double(defaultFontSize))
    let id: UInt64
    if let targetID { id = targetID } else {
      guard let document = owner.documentCoordinator.document,
            let page = document.pages.first(where: { $0.id == (context.pageID ?? document.activePageID) }) else {
        throw InkSignView.TextError.cancelled
      }
      let canonicalBounds = flowBounds.applying(page.geometry.layoutToCanonical(rotation: layoutRotation))
      id = try owner.documentCoordinator.reserveTextTarget(pageID: page.id, sourceIdentity: nil,
        fieldName: nil, canonicalBounds: canonicalBounds, options: options).id
    }
    let annotation = InkSignPdfTextAnnotation(
      id: id,
      text: text,
      bounds: InkSignPdfTextRenderer.visibleBounds(for: text,
                                                   fontSize: fontSize,
                                                   isRTL: isRTL,
                                                   flowBounds: flowBounds,
                                                   maxLines: maxLines,
                                                   verticalAnchor: verticalAnchor,
                                                   alignment: alignment),
      fontSize: fontSize,
      textColor: options?.color ?? defaultTextColor,
      isRTL: isRTL,
      flowBounds: flowBounds,
      maxLines: maxLines,
      verticalAnchor: verticalAnchor,
      alignment: alignment,
      layoutRotation: layoutRotation)
    if requireVisibleLine && (annotation.bounds.isNull || annotation.bounds.isEmpty) {
      throw InkSignView.TextError.ruleNotFound
    }
    if let pageID = context.pageID {
      try owner.appendTextAnnotation(annotation,
                                     generation: context.generation,
                                     pageID: pageID)
    } else if let pageIndex = context.pageIndex {
      owner.appendTextAnnotation(annotation,
                                 generation: context.generation,
                                 pageIndex: pageIndex)
    } else {
      throw InkSignView.TextError.cancelled
    }
  }

  func preparedDraftText(id: UInt64, pageID: UUID) -> String? {
    guard owner?.documentCoordinator.document?.activePage.id == pageID,
          case .editing(let state) = interactionState, state.id == id,
          state.generation == owner?.documentCoordinator.generation else { return nil }
    return editor?.text
  }

  @discardableResult
  func setPreparedDraftText(id: UInt64, pageID: UUID, text: String) throws -> Bool {
    guard owner?.documentCoordinator.document?.activePage.id == pageID,
          case .editing(let state) = interactionState, state.id == id,
          let editor else { return false }
    if editor.text == text { return true }
    let fullRange = NSRange(location: 0, length: (editor.text as NSString).length)
    guard admitsTextChange(in: fullRange, replacementText: text, in: editor) else {
      throw InkSignView.TextError.textDoesNotFit
    }
    editor.text = text
    textViewDidChange(editor)
    return true
  }

  func clearPreparedDraft(id: UInt64, pageID: UUID) {
    guard owner?.documentCoordinator.document?.activePage.id == pageID,
          selectedAnnotationID == id else { return }
    closeEditor()
    interactionState = .idle
    syncPresentation()
  }

  func setPreparedDraftOptions(id: UInt64, pageID: UUID, options: TextAnnotationOptions) -> Bool {
    guard owner?.documentCoordinator.document?.activePage.id == pageID,
          case .editing(var state) = interactionState, state.id == id else { return false }
    state.fontSize = CGFloat(options.fontSize ?? Double(state.fontSize))
    state.textColor = options.color ?? state.textColor
    if let direction = options.direction { state.isRTL = resolvedDirection(direction) }
    if let maxLines = options.maxLines { state.maxLines = Int(maxLines) }
    if let alignment = options.alignment { state.alignment = InkSignPdfTextAlignment(alignment) }
    if let anchor = options.verticalAnchor { state.verticalAnchor = InkSignPdfTextVerticalAnchor(anchor) }
    interactionState = .editing(state)
    if let editor { applyTextStyle(to: editor, state: state); layoutEditor() }
    return true
  }

  func preparedFontSize(id: UInt64, pageID: UUID) -> Double? {
    guard owner?.documentCoordinator.document?.activePage.id == pageID,
          case .editing(let state) = interactionState, state.id == id else { return nil }
    return Double(state.fontSize)
  }

  var preparedDefaultFontSize: Double { Double(defaultFontSize) }

  func adjustedFontSize(_ size: Double, delta: Double) -> Double {
    min(max(size + delta, Double(minimumTextFontSize)), Double(maximumTextFontSize))
  }

  private func appLayoutIsRTL() -> Bool {
    owner?.container.effectiveUserInterfaceLayoutDirection == .rightToLeft
  }

  func resolvedDirection(_ direction: TextDirection?) -> Bool {
    switch direction {
    case .some(.ltr): return false
    case .some(.rtl): return true
    case .some(.auto): return appLayoutIsRTL()
    case .none: return requestedTextDirectionRtl ?? appLayoutIsRTL()
    }
  }

  private func lineLimit(_ value: Double?) -> Int {
    guard let value, value > 0 else { return 0 }
    return value >= Double(Int.max) ? Int.max : Int(value)
  }

  private func makeFlowBounds(bounds: TextAnnotationBounds,
                              pageSize: CGSize) -> CGRect? {
    let x = CGFloat(bounds.x)
    let y = CGFloat(bounds.y)
    let width = CGFloat(bounds.width)
    let height = CGFloat(bounds.height)
    let right = x + width
    let bottom = y + height
    guard pageSize.width.isFinite, pageSize.height.isFinite,
          pageSize.width > 0, pageSize.height > 0,
          x.isFinite, y.isFinite, width.isFinite, height.isFinite,
          width > 0, height > 0, right.isFinite, bottom.isFinite,
          x >= 0, y >= 0, right <= pageSize.width, bottom <= pageSize.height else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
  }

  internal func armPlacement(generation: UInt64,
                             options: TextModeOptions? = nil) throws {
    if hasPendingPlacement() { return }
    guard let owner, let presentation = presentation() else { throw InkSignView.TextError.notReady }
    guard presentation.generation == generation else { throw InkSignView.TextError.cancelled }
    let isRTL = resolvedDirection(options?.direction)
    interactionState = .placing(PlacementState(generation: presentation.generation,
                                               pageIndex: presentation.pageIndex,
                                               isRTL: isRTL,
                                               options: options))
    if options?.width == nil,
       let requestID = beginPlacementRuleScan(generation: presentation.generation,
                                              pageID: presentation.pageID) {
      owner.schedulePlacementRuleScan(generation: presentation.generation,
                                      pageIndex: presentation.pageIndex,
                                      pageID: presentation.pageID,
                                      requestID: requestID)
    }
    emitInteractionModeChanged()
    setNeedsDisplay()
  }

  internal func cancelPendingPlacement() {
    if case .placing = interactionState { interactionState = .idle }
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
    if editor != nil {
      finishEditing()
    } else if case .dragging = interactionState {
      commitDrag()
    }
    clearSelection()
  }

  func discardForDocumentReplacement() {
    clearPlacementRules()
    closeEditor()
    interactionState = .idle
    clearSelection()
  }

  func discardForDisposal() {
    clearPlacementRules()
    closeEditor()
    interactionState = .idle
    onInteractionModeChanged = nil
    onTextSelectionChange = nil
    setNeedsDisplay()
  }

  func dispose() {
    discardForDisposal()
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
    if owner?.isPickingPageCoords == true { return nil }
    if let hit = super.hitTest(point, with: event), hit !== self { return hit }
    if hasPendingPlacement() {
      return owner?.canonicalPagePoint(fromOverlay: point) == nil ? nil : self
    }
    if editor != nil || annotation(at: point) != nil { return self }
    return nil
  }

  internal func dragTarget(at point: CGPoint) -> UInt64? {
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
          let pagePoint = displayedPagePoint(fromOverlay: point) else {
      return false
    }
    let verticalAnchor = InkSignPdfTextVerticalAnchor(placement.options?.verticalAnchor)
    let flowBounds: CGRect?
    if let options = placement.options, let width = options.width, let height = options.height {
      let bounds = TextAnnotationBounds(x: Double(pagePoint.x),
                                        y: Double(pagePoint.y),
                                        width: width,
                                        height: height)
      guard let resolved = makeFlowBounds(bounds: bounds, pageSize: presentation.pageSize) else {
        return false
      }
      flowBounds = resolved
    } else {
      flowBounds = nil
    }
    cancelPendingPlacement()
    let rule = placement.options?.width == nil
      ? placementRule(at: pagePoint, viewPoint: point, pageID: presentation.pageID,
                      isRTL: placement.isRTL)
      : nil
    placeTextAt(pagePoint,
                rule: rule,
                isRTL: placement.isRTL,
                presentation: presentation,
                flowBounds: flowBounds,
                maxLines: lineLimit(placement.options?.maxLines),
                verticalAnchor: verticalAnchor,
                alignment: InkSignPdfTextAlignment(placement.options?.alignment))
    let editorFocus = flowBounds.map { CGPoint(x: $0.midX, y: $0.midY) } ??
      editor.flatMap { displayedPagePoint(fromOverlay:
        CGPoint(x: $0.frame.midX, y: $0.frame.midY)) } ?? pagePoint
    owner?.applyTextPlacementViewport(placement.options, editorFocus: editorFocus)
    return true
  }

  @discardableResult
  func beginPlacementRuleScan(generation: UInt64, pageID: UUID) -> UInt64? {
    if placementRuleCache?.matches(generation: generation, pageID: pageID) == true {
      return nil
    }
    placementRuleRequestID &+= 1
    placementRuleCache = .scanning(generation: generation,
                                   pageID: pageID,
                                   requestID: placementRuleRequestID)
    return placementRuleRequestID
  }

  func installPlacementRules(_ rules: [InkSignPdfPlacementRule],
                             labels: [InkSignPdfKeyTextMatch] = [],
                             generation: UInt64,
                             pageID: UUID,
                             requestID: UInt64) {
    guard case .scanning(let scanGeneration, let scanPageID, let scanRequestID) = placementRuleCache,
          scanGeneration == generation,
          scanPageID == pageID,
          scanRequestID == requestID,
          owner?.documentCoordinator.generation == generation,
          owner?.documentCoordinator.document?.activePage.id == pageID else {
      return
    }
    placementRuleCache = .ready(generation: generation, pageID: pageID, rules: rules, labels: labels)
  }

  func clearPlacementRules() {
    placementRuleRequestID &+= 1
    placementRuleCache = nil
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
      annotations.append(drag.original.moving(to: drag.position, pageSize: layoutPageSize(rotation: drag.original.layoutRotation)))
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
    if owner?.isPickingPageCoords == true { return false }
    if gestureRecognizer === placementTapRecognizer {
      return placementRecognizerAdmits(at: touch.location(in: self))
    }
    if hasPendingPlacement() { return false }
    guard isTextInputGesture(gestureRecognizer) else { return true }
    return textInputRecognizerAdmits(gestureRecognizer, at: touch.location(in: self))
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer === placementTapRecognizer {
      guard let owner,
            otherGestureRecognizer !== owner.doubleTapGestureRecognizer,
            isPDFViewGesture(otherGestureRecognizer) else { return false }
      return placementRecognizerAdmits(at: gestureRecognizer.location(in: self))
    }
    guard isTextInputGesture(gestureRecognizer),
          !isTextInputGesture(otherGestureRecognizer),
          otherGestureRecognizer !== placementTapRecognizer,
          let owner,
          otherGestureRecognizer !== owner.doubleTapGestureRecognizer,
          isPDFViewGesture(otherGestureRecognizer),
          textInputRecognizerAdmits(gestureRecognizer,
                                    at: gestureRecognizer.location(in: self)) else { return false }
    return true
  }

  private func placementRecognizerAdmits(at point: CGPoint) -> Bool {
    guard let presentation = presentation(),
          case .placing(let placement) = interactionState,
          placement.generation == presentation.generation,
          placement.pageIndex == presentation.pageIndex else { return false }
    return owner?.canonicalPagePoint(fromOverlay: point) != nil
  }

  private func isTextInputGesture(_ recognizer: UIGestureRecognizer) -> Bool {
    recognizer === tapRecognizer || recognizer === dragRecognizer ||
      recognizer === selectedDragRecognizer
  }

  private func textInputRecognizerAdmits(_ recognizer: UIGestureRecognizer,
                                        at point: CGPoint) -> Bool {
    if let editor {
      guard recognizer === tapRecognizer else { return false }
      let editorPoint = editor.convert(point, from: self)
      return !editor.point(inside: editorPoint, with: nil)
    }
    if recognizer === tapRecognizer {
      return annotation(at: point) != nil
    }
    if recognizer === dragRecognizer {
      guard let target = dragTarget(at: point) else { return false }
      return target != selectedAnnotationID
    }
    if recognizer === selectedDragRecognizer {
      guard let selectedAnnotationID else { return false }
      return dragTarget(at: point) == selectedAnnotationID
    }
    return false
  }

  private func isPDFViewGesture(_ recognizer: UIGestureRecognizer) -> Bool {
    guard let owner, var view = recognizer.view else { return false }
    let pdfView = owner.documentView
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
    rule: InkSignPdfPlacementRule?,
    isRTL: Bool,
    presentation: (generation: UInt64, pageIndex: Int,
                   pageID: UUID, pageSize: CGSize,
                   annotations: [InkSignPdfTextAnnotation]),
    flowBounds: CGRect? = nil,
    maxLines: Int = 0,
    verticalAnchor: InkSignPdfTextVerticalAnchor = .top,
    alignment: InkSignPdfTextAlignment = .start
  ) {
    guard let owner, let page = owner.documentCoordinator.document?.activePage else { return }
    let id: UInt64
    do {
      let initialBounds = flowBounds ?? CGRect(origin: pagePoint, size: .zero)
      id = try owner.documentCoordinator.reserveTextTarget(pageID: page.id, sourceIdentity: nil,
        fieldName: nil, canonicalBounds: page.geometry.displayToCanonical(initialBounds), options: nil).id
    } catch {
      assertionFailure("Unable to allocate text identity: \(error)")
      return
    }
    interactionState = .editing(EditingState(id: id,
                                              generation: presentation.generation,
                                              pageIndex: presentation.pageIndex,
                                              original: nil,
                                              layoutRotation: page.geometry.rotation,
                                              position: pagePoint,
                                              placementAnchor: nil,
                                              fontSize: defaultFontSize,
                                              isRTL: isRTL,
                                              textColor: defaultTextColor,
                                              flowBounds: flowBounds,
                                              maxLines: maxLines,
                                              verticalAnchor: verticalAnchor,
                                              alignment: alignment))
    showEditor(text: "",
               initialPlacement: flowBounds == nil
                 ? InitialPlacement(tap: pagePoint, rule: rule) : nil)
    syncPresentation()
  }

  private func makeInitialPlacement(
    _ request: InitialPlacement,
    size: CGSize,
    pageSize: CGSize
  ) -> (anchor: InkSignPdfTextBoxGeometry.PlacementAnchor, frame: CGRect) {
    if let rule = request.rule, rule.y >= size.height {
      let anchor = InkSignPdfTextBoxGeometry.PlacementAnchor(
        x: request.tap.x,
        y: rule.y,
        horizontal: .centered,
        vertical: .bottom(.outerBox))
      let frame = InkSignPdfTextBoxGeometry.initialFrame(anchor: anchor,
                                                         size: size,
                                                         insets: textEditorInsets,
                                                         pageSize: pageSize)
      if abs(frame.maxY - rule.y) < 0.001 {
        return (anchor, frame)
      }
    }
    let anchor = InkSignPdfTextBoxGeometry.PlacementAnchor(
      x: request.tap.x,
      y: request.tap.y,
      horizontal: .centered,
      vertical: .bottom(.innerTextArea))
    return (anchor,
            InkSignPdfTextBoxGeometry.initialFrame(anchor: anchor,
                                                   size: size,
                                                   insets: textEditorInsets,
                                                   pageSize: pageSize))
  }

  private func placementRule(at point: CGPoint,
                             viewPoint: CGPoint,
                             pageID: UUID,
                             isRTL: Bool) -> InkSignPdfPlacementRule? {
    guard let owner,
          let page = owner.documentCoordinator.document?.activePage,
          let transform = displayedToOverlayTransform,
          case .ready(let generation, let cachedPageID, let rules, let labels) = placementRuleCache,
          generation == owner.documentCoordinator.generation,
          cachedPageID == pageID else { return nil }
    var nearest: InkSignPdfPlacementRule?
    var nearestDistance = CGFloat.infinity
    for rule in rules {
      guard rule.minX <= point.x, point.x <= rule.maxX else { continue }
      let start = CGPoint(x: rule.minX, y: rule.y).applying(transform)
      let end = CGPoint(x: rule.maxX, y: rule.y).applying(transform)
      guard abs(end.y - start.y) <= 0.001 else { continue }
      let segment = CGPoint(x: end.x - start.x, y: end.y - start.y)
      let lengthSquared = segment.x * segment.x + segment.y * segment.y
      let projection = ((viewPoint.x - start.x) * segment.x +
        (viewPoint.y - start.y) * segment.y) / lengthSquared
      let fraction = min(max(projection, 0), 1)
      let closest = CGPoint(x: start.x + fraction * segment.x,
                            y: start.y + fraction * segment.y)
      let deltaY = closest.y - viewPoint.y
      let distance = hypot(viewPoint.x - closest.x, deltaY)
      let label = labels.first { candidate in
        InkSignPdfKeyRuleSelector.select(matches: [candidate], rules: [rule], occurrence: .first,
          directionRtl: isRTL, pageSize: page.geometry.displaySize)?.rule == rule
      }
      let lineHeight: CGFloat
      if let label {
        let centerY = label.lineCenterY ?? label.bounds.midY
        let top = CGPoint(x: point.x, y: centerY - label.lineHeight / 2)
        let bottom = CGPoint(x: point.x, y: centerY + label.lineHeight / 2)
        lineHeight = hypot(bottom.applying(transform).x - top.applying(transform).x,
                           bottom.applying(transform).y - top.applying(transform).y)
      } else {
        lineHeight = editor?.font?.lineHeight ?? defaultFontSize * 1.2
      }
      let band = max(placementRuleSnapTolerance, lineHeight)
      let allowedDistance = deltaY >= 0 ? band : placementRuleSnapTolerance
      guard distance <= allowedDistance,
            distance < nearestDistance else { continue }
      nearest = rule
      nearestDistance = distance
    }
    return nearest
  }

  private func showEditor(text: String, initialPlacement: InitialPlacement? = nil) {
    closeEditor()
    guard case .editing(let state) = interactionState else { return }
    let textView = InkSignPdfTextEditorView()
    textView.delegate = self
    textView.backgroundColor = editorFill(for: state.textColor)
    textView.isOpaque = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.isScrollEnabled = false
    textView.textContainerInset = state.flowBounds == nil ? textEditorInsets : .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.textContainer.widthTracksTextView = false
    textView.text = text
    textView.overrideUserInterfaceStyle = .light
    applyTextStyle(to: textView, state: state)
    if let initialPlacement {
      let pageSize = layoutPageSize(rotation: state.layoutRotation)
      let insets = textView.textContainerInset
      let size = InkSignPdfTextEditorLayout.measure(
        textView,
        maximumWidth: pageSize.width,
        insets: insets,
        fallbackFontSize: state.fontSize,
        fixedContentWidth: state.flowBounds?.width)
      let placement = makeInitialPlacement(initialPlacement,
                                           size: size,
                                           pageSize: pageSize)
      var positioned = state
      positioned.placementAnchor = placement.anchor
      positioned.position = placement.frame.origin
      interactionState = .editing(positioned)
    }
    editor = textView
    textView.admitsInput = { [weak self, weak textView] range, replacement in
      guard let self, let textView else { return false }
      return self.admitsTextChange(in: range,
                                   replacementText: replacement,
                                   in: textView)
    }
    layoutEditor()
    addSubview(textView)
    textView.becomeFirstResponder()
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

  func textView(_ textView: UITextView,
                shouldChangeTextIn range: NSRange,
                replacementText text: String) -> Bool {
    guard textView === editor else { return true }
    return admitsTextChange(in: range, replacementText: text, in: textView)
  }

  private func admitsTextChange(in range: NSRange,
                                replacementText text: String,
                                in textView: UITextView) -> Bool {
    guard case .editing(let state) = interactionState else { return true }
    let current = (textView.text ?? "") as NSString
    let prospective = current.replacingCharacters(in: range, with: text)
    if text.isEmpty { return true }
    if let flowBounds = state.flowBounds {
      return InkSignPdfTextRenderer.fits(prospective,
                                         fontSize: state.fontSize,
                                         isRTL: state.isRTL,
                                         flowBounds: flowBounds,
                                         maxLines: state.maxLines,
                                         alignment: state.alignment)
    }
    guard let owner else { return true }
    return InkSignPdfTextRenderer.fitsMaxLines(prospective,
                                               fontSize: state.fontSize,
                                               isRTL: state.isRTL,
                                               maxLines: state.maxLines,
                                               maximumWidth: layoutPageSize(rotation: state.layoutRotation).width,
                                               alignment: state.alignment)
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    guard textView === editor else { return }
    if caretFollowEnabled { followCaretIfNeeded() }
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    guard !settlingEditor, textView === editor else { return }
    finishForLifecycle()
  }

  private func selectAndEdit(_ id: UInt64) {
    if editor != nil { finishForLifecycle() }
    guard let presentation = presentation(),
          let annotation = presentation.annotations.first(where: { $0.id == id }) else { return }
    interactionState = .editing(EditingState(id: id,
                                              generation: presentation.generation,
                                              pageIndex: presentation.pageIndex,
                                              original: annotation,
                                              layoutRotation: annotation.layoutRotation,
                                              position: annotation.flowBounds?.origin ?? annotation.position,
                                              placementAnchor: nil,
                                              fontSize: annotation.fontSize,
                                              isRTL: annotation.isRTL,
                                              textColor: annotation.textColor,
                                              flowBounds: annotation.flowBounds,
                                              maxLines: annotation.maxLines,
                                              verticalAnchor: annotation.verticalAnchor,
                                              alignment: annotation.alignment))
    showEditor(text: annotation.text)
    syncPresentation()
  }

  private func selectForDrag(_ id: UInt64, startPoint: CGPoint) -> Bool {
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
          let transform = layoutToOverlayTransform(rotation: drag.original.layoutRotation),
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
                                         pageSize: layoutPageSize(rotation: drag.original.layoutRotation))
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
    textView.layoutManager.ensureLayout(for: textView.textContainer)
    lastEditorContentSize = textView.bounds.size
    guard case .editing(let state) = interactionState else { return }
    let text = textView.text ?? ""
    let original = state.original
    var finishedID: UInt64?
    if let original {
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        owner?.removeTextAnnotation(original,
                                    generation: state.generation,
                                    pageIndex: state.pageIndex)
        finishedID = nil
      } else if owner != nil {
        let updated = settledAnnotation(state: state, text: text)
        owner?.replaceTextAnnotation(original,
                                     with: updated,
                                     type: .textEdit,
                                     generation: state.generation,
                                     pageIndex: state.pageIndex)
        finishedID = original.id
      }
    } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              owner != nil {
      let annotation = settledAnnotation(state: state, text: text)
      owner?.appendTextAnnotation(annotation,
                                  generation: state.generation,
                                  pageIndex: state.pageIndex)
      finishedID = annotation.id
    }
    closeEditor()
    interactionState = finishedID.map { .selected(id: $0) } ?? .idle
    syncPresentation()
  }

  private func settledAnnotation(state: EditingState, text: String) -> InkSignPdfTextAnnotation {
    let layoutRotation = state.layoutRotation
    if let flowBounds = state.flowBounds {
      let layoutBounds = flowBounds
      let bounds = InkSignPdfTextRenderer.visibleBounds(for: text,
                                                        fontSize: state.fontSize,
                                                        isRTL: state.isRTL,
                                                        flowBounds: layoutBounds,
                                                        maxLines: state.maxLines,
                                                        verticalAnchor: state.verticalAnchor,
                                                        alignment: state.alignment)
      return InkSignPdfTextAnnotation(id: state.id, text: text,
                                      bounds: bounds,
                                      fontSize: state.fontSize,
                                      textColor: state.textColor,
                                      isRTL: state.isRTL,
                                      flowBounds: layoutBounds,
                                      maxLines: state.maxLines,
                                      verticalAnchor: state.verticalAnchor,
                                      alignment: state.alignment,
                                      layoutRotation: layoutRotation)
    }
    let size = lastEditorContentSize
    let bounds = CGRect(origin: state.position, size: size)
    return InkSignPdfTextAnnotation(id: state.id, text: text,
                                    bounds: bounds,
                                    fontSize: state.fontSize,
                                    textColor: state.textColor,
                                    isRTL: state.isRTL,
                                    maxLines: state.maxLines,
                                    verticalAnchor: state.verticalAnchor,
                                    alignment: state.alignment,
                                    layoutRotation: layoutRotation)
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
    let updated = annotation.changingFontSize(to: fontSize, pageSize: layoutPageSize(rotation: annotation.layoutRotation))
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
          let transform = layoutToOverlayTransform(rotation: state.layoutRotation) else { return }
    let pageSize = layoutPageSize(rotation: state.layoutRotation)
    let insets = editor.textContainerInset
    let editorSize = InkSignPdfTextEditorLayout.measure(
      editor,
      maximumWidth: pageSize.width,
      insets: insets,
      fallbackFontSize: state.fontSize,
      fixedContentWidth: state.flowBounds?.width)
    let origin: CGPoint
    if let anchor = state.placementAnchor {
      origin = InkSignPdfTextBoxGeometry.initialFrame(anchor: anchor,
                                                       size: editorSize,
                                                       insets: insets,
                                                       pageSize: pageSize).origin
    } else if let flowBounds = state.flowBounds {
      let y = state.verticalAnchor == .bottom
        ? flowBounds.maxY - editorSize.height : flowBounds.minY
      origin = CGPoint(x: flowBounds.minX, y: y)
    } else {
      origin = InkSignPdfTextBoxGeometry.clampedOrigin(for: editorSize,
                                                      preferred: state.position,
                                                      pageSize: pageSize)
    }
    var updatedState = state
    updatedState.position = origin
    if updatedState.position != state.position {
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

  private func applyTextStyle(to textView: UITextView, state: EditingState) {
    InkSignPdfTextStyle.apply(to: textView,
                              fontSize: state.fontSize,
                              color: parseColor(state.textColor) ?? .black,
                              isRTL: state.isRTL,
                              alignment: state.alignment)
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

  private func selectedAnnotation() -> InkSignPdfTextAnnotation? {
    if case .dragging(let drag) = interactionState {
      return drag.original.moving(to: drag.position, pageSize: layoutPageSize(rotation: drag.original.layoutRotation))
    }
    guard let selectedAnnotationID else { return nil }
    return owner?.activeTextAnnotations().first(where: { $0.id == selectedAnnotationID })
  }

  private func annotation(at point: CGPoint) -> UInt64? {
    return owner?.activeTextAnnotations().reversed().first(where: { annotation in
      guard let transform = layoutToOverlayTransform(rotation: annotation.layoutRotation),
            let inverse = transform.invertedIfFinite else { return false }
      let pagePoint = point.applying(inverse)
      let halfHitSize = 20 / max(hypot(transform.a, transform.b), 0.001)
      let hitBounds = annotation.bounds.insetBy(dx: -max(halfHitSize - annotation.bounds.width / 2, 0),
                                                dy: -max(halfHitSize - annotation.bounds.height / 2, 0))
      let visibleBounds = annotation.bounds.applying(transform)
        .insetBy(dx: -outlineStrokeWidth / 2, dy: -outlineStrokeWidth / 2)
      return hitBounds.contains(pagePoint) || visibleBounds.contains(point)
    })?.id
  }

  private func outlineBounds(for annotation: InkSignPdfTextAnnotation,
                             transform: CGAffineTransform) -> CGRect {
    guard let geometry = owner?.documentCoordinator.document?.activePage.geometry else { return .null }
    return InkSignPdfTextBoxGeometry.outlineBounds(for: annotation.bounds,
      transform: annotation.layoutToCanonical(mediaBox: geometry.mediaBox).concatenating(transform))
  }

  private func layoutPageSize(rotation: Int) -> CGSize {
    guard let geometry = owner?.documentCoordinator.document?.activePage.geometry else {
      preconditionFailure("Active text layout requires a published page")
    }
    return PageGeometry(mediaBox: geometry.mediaBox, rotation: rotation).displaySize
  }

  private func layoutToOverlayTransform(rotation: Int) -> CGAffineTransform? {
    guard let owner, let geometry = owner.documentCoordinator.document?.activePage.geometry,
          let canonicalToOverlay = owner.pageToOverlayTransform else { return nil }
    return geometry.layoutToCanonical(rotation: rotation).concatenating(canonicalToOverlay)
  }

  private var displayedToOverlayTransform: CGAffineTransform? {
    guard let geometry = owner?.documentCoordinator.document?.activePage.geometry else { return nil }
    return layoutToOverlayTransform(rotation: geometry.rotation)
  }

  private func displayedPagePoint(fromOverlay point: CGPoint) -> CGPoint? {
    guard let owner, let canonicalPoint = owner.canonicalPagePoint(fromOverlay: point),
          let geometry = owner.documentCoordinator.document?.activePage.geometry else { return nil }
    return geometry.canonicalToDisplay(canonicalPoint)
  }

  private func presentation() -> (generation: UInt64, pageIndex: Int,
                                  pageID: UUID, pageSize: CGSize,
                                  annotations: [InkSignPdfTextAnnotation])? {
    guard let owner, let state = owner.documentCoordinator.document,
          owner.attachedOverlayPage == state.activePage.id,
          owner.pageToOverlayTransform != nil else { return nil }
    return (owner.documentCoordinator.generation, state.activePageIndex, state.activePage.id,
            state.activePage.geometry.displaySize,
            state.activePage.history.content.textAnnotations)
  }

  private var selectedAnnotationID: UInt64? {
    switch interactionState {
    case .idle, .placing: return nil
    case .editing(let state): return state.id
    case .dragging(let state): return state.original.id
    case .selected(let id): return id
    }
  }

  private var editingID: UInt64? {
    guard case .editing(let state) = interactionState else { return nil }
    return state.id
  }

  private var isUncommittedDraft: Bool {
    guard case .editing(let state) = interactionState else { return false }
    return editor != nil && state.original == nil
  }

  private var draggingID: UInt64? {
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
