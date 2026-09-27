import CoreGraphics
import Foundation

extension InkSignView {
  func allocateTextAnnotationID() -> String {
    nextTextAnnotationID &+= 1
    return "text-\(nextTextAnnotationID)"
  }

  func insertAnnotationOn(options: TextPlacementOptions?) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      if self.textInteractionOverlay.hasPendingPlacement() { return }
      try self.requireViewportReady(request: .preserve)
      self.textInteractionOverlay.finishForLifecycle()
      self.setInteractionMode(editing: false)
      try self.textInteractionOverlay.armPlacement(generation: self.documentCoordinator.generation,
                                                  options: options)
    }
  }

  func insertAnnotationOff() throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      self.textInteractionOverlay.cancelPendingPlacement()
    }
  }

  func setTextDirection(direction: TextDirection) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      self.textInteractionOverlay.setTextDirection(direction: direction)
    }
  }

  func addTextAnnotation(
    text: String,
    bounds: TextAnnotationBounds,
    options: TextAnnotationOptions?
  ) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      try self.textInteractionOverlay.addTextAnnotation(text: text,
                                                         bounds: bounds,
                                                         options: options)
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
    documentCoordinator.document?.activePage.history.content.textAnnotations ?? []
  }

  func activePageSize() -> CGSize {
    documentCoordinator.document?.activePage.geometry.mediaBox.size ?? .zero
  }

  func appendTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.documentCoordinator.generation == generation,
          let state = documentCoordinator.document,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    guard state.activePage.history.appendText(annotation) else { return }
    textInteractionOverlay.syncContent()
    emitChange()
  }

  func replaceTextAnnotation(
    _ before: InkSignPdfTextAnnotation,
    with after: InkSignPdfTextAnnotation,
    type: InkSignPdfPageContentActionType,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.documentCoordinator.generation == generation,
          let state = documentCoordinator.document,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
  guard state.activePage.history.replaceText(before: before, with: after, type: type) else { return }
    textInteractionOverlay.syncContent()
    emitChange()
  }

  func removeTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.documentCoordinator.generation == generation,
          let state = documentCoordinator.document,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    guard state.activePage.history.removeText(annotation) else { return }
    textInteractionOverlay.syncContent()
    emitChange()
  }
}
