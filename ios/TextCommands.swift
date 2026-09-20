import CoreGraphics
import Foundation

extension InkSignView {
  func allocateTextAnnotationID() -> String {
    nextTextAnnotationID &+= 1
    return "text-\(nextTextAnnotationID)"
  }

  func insertAnnotationOn() throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      if self.textInteractionOverlay.hasPendingPlacement() { return }
      try self.requireViewportReady(request: .preserve)
      self.textInteractionOverlay.finishForLifecycle()
      self.setInteractionMode(editing: false)
      self.configureTextPlacementGestureRecognition()
      try self.textInteractionOverlay.armPlacement(generation: self.generation)
    }
  }

  func insertAnnotationOff() throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      self.textInteractionOverlay.cancelPendingPlacement()
    }
  }

  func increaseTextSize() throws -> Double {
    try performOnMainSync { try self.textInteractionOverlay.increaseTextSize() }
  }

  func decreaseTextSize() throws -> Double {
    try performOnMainSync { try self.textInteractionOverlay.decreaseTextSize() }
  }

  func removeTextAnnotation() throws {
    try performOnMainSync { try self.textInteractionOverlay.removeTextAnnotation() }
  }

  func activeTextAnnotations() -> [InkSignPdfTextAnnotation] {
    documentState?.activePage.history.content.textAnnotations ?? []
  }

  func activePageSize() -> CGSize {
    documentState?.activePage.geometry.mediaBox.size ?? .zero
  }

  func appendTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.generation == generation,
          let state = documentState,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    guard state.activePage.history.appendText(annotation) else { return }
    textInteractionOverlay.syncContent()
    emitChange()
  }

  func replaceTextAnnotation(
    _ before: InkSignPdfTextAnnotation,
    with after: InkSignPdfTextAnnotation,
    kind: InkSignPdfPageContentActionKind,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.generation == generation,
          let state = documentState,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    guard state.activePage.history.replaceText(before: before, with: after, kind: kind) else { return }
    textInteractionOverlay.syncContent()
    emitChange()
  }

  func removeTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.generation == generation,
          let state = documentState,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    guard state.activePage.history.removeText(annotation) else { return }
    textInteractionOverlay.syncContent()
    emitChange()
  }
}
