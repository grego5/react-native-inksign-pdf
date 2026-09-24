import CoreGraphics
import PencilKit
import UIKit

/// Immutable committed text in canonical, media-box-relative page coordinates.
/// UIKit editor state, selection, and viewport transforms are intentionally absent.
struct InkSignPdfTextAnnotation: Equatable {
  let id: String
  let text: String
  let bounds: CGRect
  let fontSize: CGFloat
  let isRTL: Bool
  /// Canonical opaque RGB color captured with the annotation for export/rendering.
  let textColor: String

  init(id: String, text: String, bounds: CGRect, fontSize: CGFloat,
       textColor: String = "#000000", isRTL: Bool = false) {
    precondition(!id.isEmpty, "Text annotation ID must not be empty")
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
  }

  var position: CGPoint { bounds.origin }
  var intrinsicSize: CGSize { bounds.size }

  func replacingText(_ text: String, pageSize: CGSize) -> InkSignPdfTextAnnotation {
    let size = Self.intrinsicSize(of: text, fontSize: fontSize,
                                  isRTL: isRTL, maximumWidth: pageSize.width)
    let origin = Self.clippedOrigin(for: size, preferred: position, pageSize: pageSize)
    return InkSignPdfTextAnnotation(id: id,
                                    text: text,
                                    bounds: CGRect(origin: origin, size: size),
                                    fontSize: fontSize,
                                    textColor: textColor,
                                    isRTL: isRTL)
  }

  func moving(to position: CGPoint, pageSize: CGSize) -> InkSignPdfTextAnnotation {
    let origin = Self.clippedOrigin(for: bounds.size, preferred: position, pageSize: pageSize)
    return InkSignPdfTextAnnotation(id: id, text: text,
                                    bounds: CGRect(origin: origin, size: bounds.size),
                                    fontSize: fontSize,
                                    textColor: textColor,
                                    isRTL: isRTL)
  }

  func changingFontSize(to fontSize: CGFloat, pageSize: CGSize) -> InkSignPdfTextAnnotation {
    let size = Self.intrinsicSize(of: text, fontSize: fontSize,
                                  isRTL: isRTL, maximumWidth: pageSize.width)
    let origin = Self.clippedOrigin(for: size, preferred: position, pageSize: pageSize)
    return InkSignPdfTextAnnotation(id: id, text: text,
                                    bounds: CGRect(origin: origin, size: size),
                                    fontSize: fontSize,
                                    textColor: textColor,
                                    isRTL: isRTL)
  }

  static func intrinsicSize(of text: String,
                            fontSize: CGFloat,
                            isRTL: Bool = false,
                            maximumWidth: CGFloat = .greatestFiniteMagnitude) -> CGSize {
    InkSignPdfTextRenderer.intrinsicSize(of: text,
                                         fontSize: fontSize,
                                         isRTL: isRTL,
                                         maximumWidth: maximumWidth)
  }

  private static func clippedOrigin(
    for size: CGSize,
    preferred: CGPoint,
    pageSize: CGSize
  ) -> CGPoint {
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

struct InkSignPdfPageContentHistoryAction {
  let type: InkSignPdfPageContentActionType
  let before: InkSignPdfPageContentSnapshot
  let after: InkSignPdfPageContentSnapshot
}

/// One ordered, page-local history for both PencilKit drawing and text.
final class InkSignPdfPageContentHistory {
  private(set) var content: InkSignPdfPageContentSnapshot
  private(set) var undoStack: [InkSignPdfPageContentHistoryAction] = []
  private(set) var redoStack: [InkSignPdfPageContentHistoryAction] = []
  private(set) var revision: UInt64 = 0

  init(content: InkSignPdfPageContentSnapshot = InkSignPdfPageContentSnapshot(
    drawing: PKDrawing(), textAnnotations: [])) {
    self.content = content
  }

  var state: (canUndo: Bool, canRedo: Bool, isDirty: Bool) {
    (canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty, isDirty: !content.isEmpty)
  }

  @discardableResult
  func record(
    type: InkSignPdfPageContentActionType,
    before: InkSignPdfPageContentSnapshot,
    after: InkSignPdfPageContentSnapshot
  ) -> Bool {
    guard !before.equals(after) else { return false }
    guard content.equals(before) else { return false }
    content = after
    undoStack.append(InkSignPdfPageContentHistoryAction(type: type, before: before, after: after))
    redoStack.removeAll(keepingCapacity: true)
    revision &+= 1
    return true
  }

  @discardableResult
  func appendText(_ annotation: InkSignPdfTextAnnotation) -> Bool {
    guard !content.textAnnotations.contains(where: { $0.id == annotation.id }) else { return false }
    var annotations = content.textAnnotations
    annotations.append(annotation)
    return record(type: .textCreate, before: content, after: content.replacingText(annotations))
  }

  @discardableResult
  func replaceText(
    before: InkSignPdfTextAnnotation,
    with annotation: InkSignPdfTextAnnotation,
    type: InkSignPdfPageContentActionType
  ) -> Bool {
    guard let index = content.textAnnotations.firstIndex(where: { $0.id == before.id }),
          content.textAnnotations[index] == before,
          before.id == annotation.id else { return false }
    var annotations = content.textAnnotations
    annotations[index] = annotation
    return record(type: type, before: content, after: content.replacingText(annotations))
  }

  @discardableResult
  func removeText(_ annotation: InkSignPdfTextAnnotation) -> Bool {
    guard let index = content.textAnnotations.firstIndex(where: { $0.id == annotation.id }),
          content.textAnnotations[index] == annotation else { return false }
    var annotations = content.textAnnotations
    annotations.remove(at: index)
    return record(type: .textDelete, before: content, after: content.replacingText(annotations))
  }

  func clear() {
    guard !content.isEmpty else { return }
    record(type: .clear, before: content,
           after: InkSignPdfPageContentSnapshot(drawing: PKDrawing(), textAnnotations: []))
  }

  @discardableResult
  func undo() -> Bool {
    guard let action = undoStack.popLast() else { return false }
    precondition(content.equals(action.after), "Undo content does not match the current page")
    content = action.before
    redoStack.append(action)
    revision &+= 1
    return true
  }

  @discardableResult
  func redo() -> Bool {
    guard let action = redoStack.popLast() else { return false }
    precondition(content.equals(action.before), "Redo content does not match the current page")
    content = action.after
    undoStack.append(action)
    revision &+= 1
    return true
  }
}
