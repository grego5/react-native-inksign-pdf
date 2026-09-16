import CoreGraphics
import Foundation
import NitroModules

extension PdfView {
  func allocateTextAnnotationID() -> String {
    nextTextAnnotationID &+= 1
    return "text-\(nextTextAnnotationID)"
  }

  func insertAnnotationOn() throws -> Promise<Void> {
    let promise = Promise<Void>()
    publicationLock.lock()
    let requestGeneration = generation
    publicationLock.unlock()
    performOnMain {
      guard !self.disposed, self.generation == requestGeneration else {
        promise.reject(withError: TextError.cancelled)
        return
      }
      do {
        if self.textInteractionOverlay.hasPendingPlacement() {
          promise.resolve(withResult: ())
          return
        }
        try self.requireViewportReady(request: .preserve)
        self.textInteractionOverlay.finishForLifecycle()
        self.setInteractionMode(editing: false)
        self.configureTextPlacementGestureRecognition()
        try self.textInteractionOverlay.armPlacement(generation: requestGeneration)
        guard !self.disposed, self.generation == requestGeneration else {
          self.textInteractionOverlay.finishForLifecycle()
          promise.reject(withError: TextError.cancelled)
          return
        }
        promise.resolve(withResult: ())
      } catch {
        promise.reject(withError: error)
      }
    }
    return promise
  }

  func insertAnnotationOff() throws -> Promise<Void> {
    let promise = Promise<Void>()
    publicationLock.lock()
    let requestGeneration = generation
    publicationLock.unlock()
    performOnMain {
      guard !self.disposed, self.generation == requestGeneration else {
        promise.reject(withError: TextError.cancelled)
        return
      }
      self.textInteractionOverlay.cancelPendingPlacement()
      promise.resolve(withResult: ())
    }
    return promise
  }

  func increaseTextSize() throws -> Promise<Void> {
    runTextCommand { try self.textInteractionOverlay.increaseTextSize() }
  }

  func decreaseTextSize() throws -> Promise<Void> {
    runTextCommand { try self.textInteractionOverlay.decreaseTextSize() }
  }

  func removeTextAnnotation() throws -> Promise<Void> {
    runTextCommand { try self.textInteractionOverlay.removeTextAnnotation() }
  }

  private func runTextCommand(_ action: @escaping () throws -> Void) -> Promise<Void> {
    let promise = Promise<Void>()
    publicationLock.lock()
    let requestGeneration = generation
    publicationLock.unlock()
    performOnMain {
      guard !self.disposed, self.generation == requestGeneration else {
        promise.reject(withError: TextError.cancelled)
        return
      }
      do {
        try action()
        guard !self.disposed, self.generation == requestGeneration else {
          promise.reject(withError: TextError.cancelled)
          return
        }
        promise.resolve(withResult: ())
      } catch {
        promise.reject(withError: error)
      }
    }
    return promise
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
