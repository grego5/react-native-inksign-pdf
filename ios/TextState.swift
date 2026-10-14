import CoreGraphics
import PencilKit
import UIKit

enum InkSignPdfTextVerticalAnchor: Equatable {
  case top
  case bottom

  init(_ value: TextVerticalAnchor?) {
    self = value == .bottom ? .bottom : .top
  }

}

enum InkSignPdfTextAlignment: Equatable {
  case start
  case end
  case center

  init(_ value: TextAlignment?) {
    switch value {
    case .some(.start): self = .start
    case .some(.end): self = .end
    case .some(.center): self = .center
    case .none: self = .start
    }
  }
}

enum InkSignPdfTextBoxGeometry {
  enum BottomEdge: Equatable {
    case innerTextArea
    case outerBox
  }

  struct PlacementAnchor: Equatable {
    enum Horizontal: Equatable {
      case centered
      case left
      case right
    }

    enum Vertical: Equatable {
      case top
      case bottom(BottomEdge)
    }

    let x: CGFloat
    let y: CGFloat
    let horizontal: Horizontal
    let vertical: Vertical
  }

  static func initialFrame(anchor: PlacementAnchor,
                           size: CGSize,
                           insets: UIEdgeInsets,
                           pageSize: CGSize) -> CGRect {
    let x: CGFloat
    switch anchor.horizontal {
    case .centered: x = anchor.x - size.width / 2
    case .left: x = anchor.x
    case .right: x = anchor.x - size.width
    }
    let y: CGFloat
    switch anchor.vertical {
    case .top:
      y = anchor.y
    case .bottom(let edge):
      let bottomInset = edge == .innerTextArea ? insets.bottom : 0
      y = anchor.y - size.height + bottomInset
    }
    let origin = CGPoint(x: x, y: y)
    return CGRect(origin: clampedOrigin(for: size, preferred: origin, pageSize: pageSize),
                  size: size)
  }

  static func outlineBounds(for bounds: CGRect,
                            transform: CGAffineTransform) -> CGRect {
    bounds.applying(transform)
  }

  static func clampedOrigin(for size: CGSize,
                            preferred: CGPoint,
                            pageSize: CGSize) -> CGPoint {
    precondition(pageSize.width.isFinite && pageSize.height.isFinite &&
                   pageSize.width > 0 && pageSize.height > 0,
                 "Text annotation page size must be finite and positive")
    let x = size.width >= pageSize.width
      ? (pageSize.width - size.width) / 2
      : min(max(preferred.x, 0), pageSize.width - size.width)
    let y = size.height >= pageSize.height
      ? (pageSize.height - size.height) / 2
      : min(max(preferred.y, 0), pageSize.height - size.height)
    return CGPoint(x: x, y: y)
  }
}

/// Immutable committed text in the page orientation captured when it was laid out.
/// UIKit editor state, selection, and viewport transforms are intentionally absent.
struct InkSignPdfTextAnnotation: Equatable {
  let id: UInt64
  let text: String
  /// Measured visible text bounds used for selection and auto-sized placement.
  let bounds: CGRect
  let fontSize: CGFloat
  let isRTL: Bool
  /// Canonical opaque RGB color captured with the annotation for export/rendering.
  let textColor: String
  /// Fixed physical flow rectangle in saved layout coordinates. Its edges
  /// stay left-to-right and top-to-bottom regardless of writing direction.
  let flowBounds: CGRect?
  /// Maximum number of complete source-order lines, or zero for no line-count limit.
  let maxLines: Int
  let verticalAnchor: InkSignPdfTextVerticalAnchor
  /// Logical alignment resolved inside `flowBounds` using the saved direction.
  let alignment: InkSignPdfTextAlignment
  /// Orientation whose displayed coordinates define this text layout.
  let layoutRotation: Int
  let font: InkSignPdfNamedFont?

  init(id: UInt64, text: String, bounds: CGRect, fontSize: CGFloat,
       textColor: String = "#000000", isRTL: Bool = false,
       flowBounds: CGRect? = nil,
       maxLines: Int = 0,
       verticalAnchor: InkSignPdfTextVerticalAnchor = .top,
       alignment: InkSignPdfTextAlignment = .start,
       layoutRotation: Int = 0, font: InkSignPdfNamedFont? = nil) {
    precondition(id > 0, "Text annotation ID must be positive")
    precondition(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                 "Committed text annotation must not be blank")
    precondition(bounds.minX.isFinite && bounds.minY.isFinite &&
                   bounds.width.isFinite && bounds.height.isFinite &&
                   bounds.width >= 0 && bounds.height >= 0,
                 "Text annotation bounds must be finite and non-negative")
    precondition(fontSize.isFinite && fontSize > 0,
                 "Text annotation font size must be finite and positive")
    self.id = id
    self.text = text
    self.bounds = bounds
    self.fontSize = fontSize
    self.isRTL = isRTL
    self.textColor = textColor
    self.flowBounds = flowBounds
    self.maxLines = maxLines
    self.verticalAnchor = verticalAnchor
    self.alignment = alignment
    self.layoutRotation = PageGeometry.normalizedRotation(layoutRotation)
    self.font = font
  }

  var position: CGPoint { bounds.origin }
  var intrinsicSize: CGSize { bounds.size }

  func layoutToCanonical(mediaBox: CGRect) -> CGAffineTransform {
    PageGeometry(mediaBox: mediaBox, rotation: 0).layoutToCanonical(rotation: layoutRotation)
  }

  func canonicalPlacementBounds(mediaBox: CGRect) -> CGRect {
    (flowBounds ?? bounds).applying(layoutToCanonical(mediaBox: mediaBox))
  }

  func replacingText(_ text: String, pageSize: CGSize) -> InkSignPdfTextAnnotation {
    if let flowBounds {
      let bounds = InkSignPdfTextRenderer.visibleBounds(for: text,
                                                        fontSize: fontSize,
                                                        isRTL: isRTL,
                                                        flowBounds: flowBounds,
                                                        maxLines: maxLines,
                                                        verticalAnchor: verticalAnchor,
                                                        alignment: alignment, font: font)
      return InkSignPdfTextAnnotation(id: id, text: text, bounds: bounds,
                                      fontSize: fontSize, textColor: textColor,
                                      isRTL: isRTL, flowBounds: flowBounds,
                                      maxLines: maxLines, verticalAnchor: verticalAnchor,
                                      alignment: alignment, layoutRotation: layoutRotation, font: font)
    }
    let size = Self.intrinsicSize(of: text, fontSize: fontSize,
                                  isRTL: isRTL, maximumWidth: pageSize.width, font: font)
    let origin = InkSignPdfTextBoxGeometry.clampedOrigin(for: size,
                                                        preferred: position,
                                                        pageSize: pageSize)
    return InkSignPdfTextAnnotation(id: id,
                                    text: text,
                                    bounds: CGRect(origin: origin, size: size),
                                    fontSize: fontSize,
                                    textColor: textColor,
                                    isRTL: isRTL,
                                    maxLines: maxLines,
                                    verticalAnchor: verticalAnchor,
                                    alignment: alignment,
                                    layoutRotation: layoutRotation, font: font)
  }

  func moving(to position: CGPoint, pageSize: CGSize) -> InkSignPdfTextAnnotation {
    let sourceFrame = flowBounds ?? bounds
    let requestedFrameOrigin = CGPoint(x: sourceFrame.minX + position.x - bounds.minX,
                                       y: sourceFrame.minY + position.y - bounds.minY)
    let origin = InkSignPdfTextBoxGeometry.clampedOrigin(for: sourceFrame.size,
                                                        preferred: requestedFrameOrigin,
                                                        pageSize: pageSize)
    let offset = CGPoint(x: origin.x - sourceFrame.minX, y: origin.y - sourceFrame.minY)
    let movedFlowBounds = flowBounds.map { $0.offsetBy(dx: offset.x, dy: offset.y) }
    let movedBounds = movedFlowBounds.map {
      InkSignPdfTextRenderer.visibleBounds(for: text, fontSize: fontSize,
                                           isRTL: isRTL, flowBounds: $0,
                                           maxLines: maxLines,
                                           verticalAnchor: verticalAnchor,
                                           alignment: alignment, font: font)
    } ?? bounds.offsetBy(dx: offset.x, dy: offset.y)
    return InkSignPdfTextAnnotation(id: id, text: text,
                                    bounds: movedBounds,
                                    fontSize: fontSize,
                                    textColor: textColor,
                                    isRTL: isRTL,
                                    flowBounds: movedFlowBounds,
                                    maxLines: maxLines,
                                    verticalAnchor: verticalAnchor,
                                    alignment: alignment,
                                    layoutRotation: layoutRotation, font: font)
  }

  func changingFontSize(to fontSize: CGFloat, pageSize: CGSize) -> InkSignPdfTextAnnotation {
    if let flowBounds {
      let bounds = InkSignPdfTextRenderer.visibleBounds(for: text,
                                                        fontSize: fontSize,
                                                        isRTL: isRTL,
                                                        flowBounds: flowBounds,
                                                        maxLines: maxLines,
                                                        verticalAnchor: verticalAnchor,
                                                        alignment: alignment, font: font)
      return InkSignPdfTextAnnotation(id: id, text: text, bounds: bounds,
                                      fontSize: fontSize, textColor: textColor,
                                      isRTL: isRTL, flowBounds: flowBounds,
                                      maxLines: maxLines, verticalAnchor: verticalAnchor,
                                      alignment: alignment, layoutRotation: layoutRotation, font: font)
    }
    let size = Self.intrinsicSize(of: text, fontSize: fontSize,
                                  isRTL: isRTL, maximumWidth: pageSize.width, font: font)
    let origin = InkSignPdfTextBoxGeometry.clampedOrigin(for: size,
                                                        preferred: position,
                                                        pageSize: pageSize)
    return InkSignPdfTextAnnotation(id: id, text: text,
                                    bounds: CGRect(origin: origin, size: size),
                                    fontSize: fontSize,
                                    textColor: textColor,
                                    isRTL: isRTL,
                                    maxLines: maxLines,
                                    verticalAnchor: verticalAnchor,
                                    alignment: alignment,
                                    layoutRotation: layoutRotation, font: font)
  }

  static func intrinsicSize(of text: String,
                            fontSize: CGFloat,
                            isRTL: Bool = false,
                            maximumWidth: CGFloat = .greatestFiniteMagnitude,
                            font: InkSignPdfNamedFont? = nil) -> CGSize {
    InkSignPdfTextRenderer.intrinsicSize(of: text,
                                         fontSize: fontSize,
                                         isRTL: isRTL,
                                         maximumWidth: maximumWidth, font: font)
  }

}

/// The immutable page-content snapshot shared by history and downstream boundaries.
struct InkSignPdfPageContentSnapshot {
  let drawing: PKDrawing
  let textAnnotations: [InkSignPdfTextAnnotation]

  var isEmpty: Bool { drawing.strokes.isEmpty && textAnnotations.isEmpty }

  func replacingDrawing(_ drawing: PKDrawing) -> InkSignPdfPageContentSnapshot {
    InkSignPdfPageContentSnapshot(drawing: drawing, textAnnotations: textAnnotations)
  }

  func replacingText(_ annotations: [InkSignPdfTextAnnotation]) -> InkSignPdfPageContentSnapshot {
    InkSignPdfPageContentSnapshot(drawing: drawing, textAnnotations: annotations)
  }

  func equals(_ other: InkSignPdfPageContentSnapshot) -> Bool {
    drawing.dataRepresentation() == other.drawing.dataRepresentation() &&
      textAnnotations == other.textAnnotations
  }
}

enum InkSignPdfPageContentActionType: Equatable {
  case ink
  case textCreate
  case textEdit
  case textMove
  case textFont
  case textDelete
  case clear
}

struct InkSignPdfTextOverride {
  let id: UInt64
  let annotation: InkSignPdfTextAnnotation?
  let order: UInt64
}

struct InkSignPdfTextHistoryChange {
  let id: UInt64
  let before: InkSignPdfTextOverride?
  let after: InkSignPdfTextOverride?
}

struct InkSignPdfDrawingHistoryChange {
  let before: PKDrawing?
  let after: PKDrawing?
}

struct InkSignPdfPageContentHistoryAction {
  let type: InkSignPdfPageContentActionType
  let text: [InkSignPdfTextHistoryChange]
  let drawing: InkSignPdfDrawingHistoryChange?
}

/// Permanent base plus keyed tracked overrides. Undo never restores unrelated base content.
final class InkSignPdfPageContentHistory {
  struct TextPreview {
    let id: UInt64
    let annotation: InkSignPdfTextAnnotation?
    let changed: Bool
  }
  var textPreview: TextPreview? { didSet { revision &+= 1 } }
  private var base: InkSignPdfPageContentSnapshot
  private var baseTextByID: [UInt64: InkSignPdfTextAnnotation]
  private var textOverrides: [UInt64: InkSignPdfTextOverride] = [:]
  private var drawingOverride: PKDrawing?
  private var nextOrder: UInt64 = 0
  private let recordHistory: Bool
  private var retainedTextCounts: [UInt64: Int] = [:]
  private(set) var undoStack: [InkSignPdfPageContentHistoryAction] = []
  private(set) var redoStack: [InkSignPdfPageContentHistoryAction] = []
  private(set) var revision: UInt64 = 0

  init(content: InkSignPdfPageContentSnapshot = InkSignPdfPageContentSnapshot(
    drawing: PKDrawing(), textAnnotations: []), recordHistory: Bool = true) {
    base = content
    baseTextByID = Dictionary(uniqueKeysWithValues: content.textAnnotations.map { ($0.id, $0) })
    self.recordHistory = recordHistory
  }

  var content: InkSignPdfPageContentSnapshot {
    var text = base.textAnnotations.filter { textOverrides[$0.id] == nil } +
      textOverrides.values.sorted { $0.order < $1.order }.compactMap(\.annotation)
    if let preview = textPreview {
      text.removeAll { $0.id == preview.id }
      if let annotation = preview.annotation { text.append(annotation) }
    }
    return InkSignPdfPageContentSnapshot(drawing: drawingOverride ?? base.drawing, textAnnotations: text)
  }

  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }
  var state: (canUndo: Bool, canRedo: Bool, isDirty: Bool) {
    (canUndo, canRedo, canUndo || (recordHistory && textPreview?.changed == true))
  }

  func hasRetainedHistory(for id: UInt64) -> Bool {
    textOverrides[id] != nil || retainedTextCounts[id] != nil
  }

  var drawing: PKDrawing { drawingOverride ?? base.drawing }

  func text(for id: UInt64) -> InkSignPdfTextAnnotation? {
    if let preview = textPreview, preview.id == id { return preview.annotation }
    if let override = textOverrides[id] { return override.annotation }
    return baseTextByID[id]
  }

  private func appendAction(_ action: InkSignPdfPageContentHistoryAction) {
    for discarded in redoStack {
      for change in discarded.text {
        let remaining = (retainedTextCounts[change.id] ?? 0) - 1
        retainedTextCounts[change.id] = remaining > 0 ? remaining : nil
      }
    }
    redoStack.removeAll(keepingCapacity: true)
    for change in action.text { retainedTextCounts[change.id, default: 0] += 1 }
    undoStack.append(action)
  }

  private func recordText(id: UInt64, annotation: InkSignPdfTextAnnotation?,
                           type: InkSignPdfPageContentActionType, untracked: Bool) -> Bool {
    if !recordHistory || (untracked && !hasRetainedHistory(for: id)) {
      var text = base.textAnnotations
      if let index = text.firstIndex(where: { $0.id == id }) {
        if let annotation { text[index] = annotation } else { text.remove(at: index) }
      } else if let annotation { text.append(annotation) }
      baseTextByID[id] = annotation
      base = base.replacingText(text)
    } else {
      let previous = textOverrides[id]
      let order = previous?.order ?? nextOrder
      if previous == nil { nextOrder &+= 1 }
      let next = InkSignPdfTextOverride(id: id, annotation: annotation, order: order)
      textOverrides[id] = next
      appendAction(InkSignPdfPageContentHistoryAction(type: type,
        text: [InkSignPdfTextHistoryChange(id: id, before: previous, after: next)], drawing: nil))
    }
    revision &+= 1
    return true
  }

  @discardableResult
  func recordDrawing(_ next: PKDrawing, replacing baseline: PKDrawing,
                      type: InkSignPdfPageContentActionType = .ink) -> Bool {
    let current = drawing.dataRepresentation()
    guard current == baseline.dataRepresentation(), current != next.dataRepresentation() else { return false }
    if recordHistory {
      let change = InkSignPdfDrawingHistoryChange(before: drawingOverride, after: next)
      drawingOverride = next
      appendAction(InkSignPdfPageContentHistoryAction(type: type, text: [], drawing: change))
    } else { base = base.replacingDrawing(next) }
    revision &+= 1
    return true
  }

  @discardableResult
  func record(type: InkSignPdfPageContentActionType,
              before: InkSignPdfPageContentSnapshot,
              after: InkSignPdfPageContentSnapshot,
              untracked: Bool = false) -> Bool {
    guard !before.equals(after), content.equals(before) else { return false }
    let old = Dictionary(uniqueKeysWithValues: before.textAnnotations.map { ($0.id, $0) })
    let new = Dictionary(uniqueKeysWithValues: after.textAnnotations.map { ($0.id, $0) })
    let ids = Array(Set(old.keys).union(new.keys)).filter { old[$0] != new[$0] }.sorted()
    let drawingChanged = before.drawing.dataRepresentation() != after.drawing.dataRepresentation()
    let mayUseBase = !recordHistory || (untracked && !drawingChanged &&
      ids.allSatisfy { !hasRetainedHistory(for: $0) })
    if mayUseBase {
      var text = base.textAnnotations
      for id in ids {
        text.removeAll { $0.id == id }
        if let annotation = new[id] { text.append(annotation) }
      }
      base = InkSignPdfPageContentSnapshot(drawing: drawingChanged ? after.drawing : base.drawing,
                                           textAnnotations: text)
      baseTextByID = Dictionary(uniqueKeysWithValues: text.map { ($0.id, $0) })
      revision &+= 1
      return true
    }
    let changes = ids.map { id -> InkSignPdfTextHistoryChange in
      let previous = textOverrides[id]
      let order: UInt64
      if let previous { order = previous.order }
      else { order = nextOrder; nextOrder &+= 1 }
      let next = InkSignPdfTextOverride(id: id, annotation: new[id], order: order)
      textOverrides[id] = next
      return InkSignPdfTextHistoryChange(id: id, before: previous, after: next)
    }
    let drawing = drawingChanged
      ? InkSignPdfDrawingHistoryChange(before: drawingOverride, after: after.drawing) : nil
    if drawingChanged { drawingOverride = after.drawing }
    appendAction(InkSignPdfPageContentHistoryAction(type: type, text: changes, drawing: drawing))
    revision &+= 1
    return true
  }

  @discardableResult
  func appendText(_ annotation: InkSignPdfTextAnnotation, untracked: Bool = false) -> Bool {
    guard text(for: annotation.id) == nil else { return false }
    return recordText(id: annotation.id, annotation: annotation, type: .textCreate, untracked: untracked)
  }

  @discardableResult
  func replaceText(before: InkSignPdfTextAnnotation, with annotation: InkSignPdfTextAnnotation,
                   type: InkSignPdfPageContentActionType, untracked: Bool = false) -> Bool {
    guard text(for: before.id) == before, before.id == annotation.id, before != annotation else { return false }
    return recordText(id: annotation.id, annotation: annotation, type: type, untracked: untracked)
  }

  @discardableResult
  func removeText(_ annotation: InkSignPdfTextAnnotation, untracked: Bool = false) -> Bool {
    guard text(for: annotation.id) == annotation else { return false }
    return recordText(id: annotation.id, annotation: nil, type: .textDelete, untracked: untracked)
  }

  func clear() {
    let before = content
    guard !before.isEmpty else { return }
    record(type: .clear, before: before,
           after: InkSignPdfPageContentSnapshot(drawing: PKDrawing(), textAnnotations: []))
  }

  @discardableResult
  func undo() -> Bool {
    guard let action = undoStack.popLast() else { return false }
    for change in action.text { textOverrides[change.id] = change.before }
    if let change = action.drawing { drawingOverride = change.before }
    redoStack.append(action)
    revision &+= 1
    return true
  }

  @discardableResult
  func redo() -> Bool {
    guard let action = redoStack.popLast() else { return false }
    for change in action.text { textOverrides[change.id] = change.after }
    if let change = action.drawing { drawingOverride = change.after }
    undoStack.append(action)
    revision &+= 1
    return true
  }
}
