import Foundation
import PencilKit

extension DocumentCore {
  func appendText(_ annotation: InkSignPdfTextAnnotation, context: InkSignPdfCorePageContext,
                  untracked: Bool = false) throws {
    try requireContentMutationReady()
    let page = try self.page(context)
    guard page.history.appendText(annotation, untracked: untracked) else { return }
    coordinator.updateTextPlacement(annotation, page: page)
    changed(.page(page.id))
  }
  func replaceText(_ original: InkSignPdfTextAnnotation, with annotation: InkSignPdfTextAnnotation,
                   type: InkSignPdfPageContentActionType, context: InkSignPdfCorePageContext) throws {
    try requireContentMutationReady()
    let page = try self.page(context)
    guard page.history.replaceText(before: original, with: annotation, type: type) else { return }
    coordinator.updateTextPlacement(annotation, page: page)
    changed(.page(page.id))
  }
  func removeText(_ original: InkSignPdfTextAnnotation, context: InkSignPdfCorePageContext) throws {
    try requireContentMutationReady()
    let page = try self.page(context)
    guard page.history.removeText(original) else { return }
    changed(.page(page.id))
  }
  func commitDrawing(_ drawing: PKDrawing, replacing baseline: PKDrawing,
                     context: InkSignPdfCorePageContext) throws -> Bool {
    try requireContentMutationReady()
    let page = try self.page(context)
    guard page.history.recordDrawing(drawing, replacing: baseline) else { return false }
    changed(.page(page.id))
    return true
  }
  func undo(_ context: InkSignPdfCorePageContext) throws {
    try requireContentMutationReady()
    let page = try self.page(context)
    endTextEdit()
    guard page.history.undo() else { return }
    coordinator.synchronizeTextPlacement(on: page)
    changed(.page(page.id))
  }
  func redo(_ context: InkSignPdfCorePageContext) throws {
    try requireContentMutationReady()
    let page = try self.page(context)
    endTextEdit()
    guard page.history.redo() else { return }
    coordinator.synchronizeTextPlacement(on: page)
    changed(.page(page.id))
  }
  func clear(_ context: InkSignPdfCorePageContext, inkOnly: Bool = false) throws {
    try requireContentMutationReady()
    let page = try self.page(context)
    endTextEdit()
    let revision = page.history.revision
    if inkOnly {
      let drawing = page.history.drawing
      if !drawing.strokes.isEmpty { _ = page.history.recordDrawing(PKDrawing(), replacing: drawing, type: .clear) }
    } else { page.history.clear() }
    changed(.inkCleared(page.id))
    guard revision != page.history.revision else { return }
    changed(.page(page.id))
  }
}
