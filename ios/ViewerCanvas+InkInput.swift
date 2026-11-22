import CoreGraphics
import PencilKit
import UIKit

extension ViewerCanvas {
  /// PencilKit owns high-frequency input, smoothing, pressure handling, and
  /// prediction. PencilKit's begin/end tool callbacks own the interaction
  /// lifecycle; the recognizer target is only used to coordinate cancellation.
  /// The coordinator keeps an ended interaction open until this callback
  /// delivers the drawing revision that follows tool completion.
  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard canvasView === self.canvasView,
          !self.canvasView.isInstallingDrawing else { return }
    if let transactionID = endedDrawingTransactionID {
      finishEndedDrawingTransaction(transactionID: transactionID)
      return
    }
    if activeDrawingTransactionID == nil {
      // A cancelled transaction may still produce a late delegate callback.
      // Restore the authoritative snapshot instead of accepting that update.
      installCommittedDrawing()
    }
  }

  /// This is the supported PencilKit transaction boundary. The custom gesture
  /// recognizer may observe .began before or after this callback, so it only
  /// receives the coordinator's ID through canvasGestureWillBegin.
  func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
    guard canvasView === self.canvasView,
          interaction.acceptsInkInput, viewerDocument != nil,
          pageToOverlayTransform != nil,
          activeDrawingTransactionID == nil,
          endedDrawingTransactionID == nil else {
      self.canvasView.cancelDrawingInteraction()
      return
    }
    let transactionID: UInt64
    if let pendingDrawingTransactionID {
      transactionID = pendingDrawingTransactionID
    } else {
      nextDrawingTransactionID &+= 1
      transactionID = nextDrawingTransactionID
    }
    pendingDrawingTransactionID = nil
    activeDrawingTransactionID = transactionID
    activeDrawingContext = viewerDocument.map {
      InkSignPdfCorePageContext(generation: documentCoordinator.generation, pageID: $0.activePage.id)
    }
    activeDrawingBaseline = viewerDocument?.activePage.history.content
    activeDrawingPageToOverlayTransform = pageToOverlayTransform
  }

  /// PencilKit documents that the final force values can arrive after this
  /// callback. Move, rather than commit, the transaction so the following
  /// drawing-change callback still belongs to this transaction.
  func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
    guard canvasView === self.canvasView,
          let transactionID = activeDrawingTransactionID,
          let baseline = activeDrawingBaseline else {
      return
    }
    pendingDrawingTransactionID = nil
    endedDrawingTransactionID = transactionID
    endedDrawingContext = activeDrawingContext
    endedDrawingBaseline = baseline
    endedDrawingPageToOverlayTransform = activeDrawingPageToOverlayTransform
    activeDrawingTransactionID = nil
    activeDrawingContext = nil
    activeDrawingBaseline = nil
    activeDrawingPageToOverlayTransform = nil
  }

  func canvasGestureWillBegin(_ canvas: InkCanvasView) -> UInt64? {
    interaction.viewport.cancelMotion()
    guard canvas === canvasView, interaction.acceptsInkInput, viewerDocument != nil,
          pageToOverlayTransform != nil else {
      return nil
    }
    if let activeDrawingTransactionID {
      return activeDrawingTransactionID
    }
    guard endedDrawingTransactionID == nil else { return nil }
    if let pendingDrawingTransactionID {
      return pendingDrawingTransactionID
    }
    nextDrawingTransactionID &+= 1
    pendingDrawingTransactionID = nextDrawingTransactionID
    return nextDrawingTransactionID
  }

  func canvasDidCancelDrawing(_ canvas: InkCanvasView, transactionID: UInt64) {
    guard canvas === canvasView,
          activeDrawingTransactionID == transactionID ||
          pendingDrawingTransactionID == transactionID ||
          endedDrawingTransactionID == transactionID else { return }
    cancelActiveStroke()
  }

  /// Cancels the coordinator transaction and PencilKit's gesture recognizer as
  /// one operation. Disabling and re-enabling the recognizer resets its
  /// internal touch tracking, so late callbacks cannot revive cancelled ink.
  func cancelActiveStroke(clearLive: Bool = true) {
    let hadInteraction = pendingDrawingTransactionID != nil ||
      activeDrawingTransactionID != nil ||
      endedDrawingTransactionID != nil
    pendingDrawingTransactionID = nil
    activeDrawingTransactionID = nil
    activeDrawingContext = nil
    activeDrawingBaseline = nil
    activeDrawingPageToOverlayTransform = nil
    endedDrawingTransactionID = nil
    endedDrawingContext = nil
    endedDrawingBaseline = nil
    endedDrawingPageToOverlayTransform = nil
    if hadInteraction { canvasView.cancelDrawingInteraction() }
    if clearLive { installCommittedDrawing() }
    installPenAfterDrawing()
  }

  /// Retain PencilKit's final visible drawing through synchronous core
  /// publication. The page observer recognizes this as the local transaction.
  func finishEndedDrawingTransaction(transactionID: UInt64) {
    guard endedDrawingTransactionID == transactionID else { return }
    guard let baseline = endedDrawingBaseline,
          let transform = endedDrawingPageToOverlayTransform,
          let context = endedDrawingContext,
          context.generation == documentCoordinator.generation,
          viewerDocument?.activePageID == context.pageID else {
      cancelActiveStroke()
      return
    }
    let finished = canonicalDrawing(from: canvasView.drawing, using: transform)
    var adopted = sameDrawing(finished, baseline.drawing)
    if !adopted {
      adopted = (try? documentCore.commitDrawing(finished, replacing: baseline.drawing,
        context: context)) == true
    }
    // A synchronous observer may already have cancelled/replaced the input.
    guard endedDrawingTransactionID == transactionID else { return }
    endedDrawingTransactionID = nil
    endedDrawingContext = nil
    endedDrawingBaseline = nil
    endedDrawingPageToOverlayTransform = nil
    if !adopted { installCommittedDrawing() }
    installPenAfterDrawing()
    emitChange()
  }

  var hasDrawingTransaction: Bool {
    pendingDrawingTransactionID != nil ||
      activeDrawingTransactionID != nil || endedDrawingTransactionID != nil
  }

  func installCommittedDrawing() {
    let displayed: PKDrawing
    let committedDrawing = viewerDocument?.activePage.history.content.drawing ?? PKDrawing()
    if let activePageID = viewerDocument?.activePage.id,
       attachedOverlayPage == activePageID,
       overlayTransformPage == activePageID,
       let transform = pageToOverlayTransform {
      if sameDrawing(canonicalDrawing(from: canvasView.drawing, using: transform), committedDrawing) {
        return
      }
      displayed = committedDrawing.transformed(using: transform)
    } else {
      displayed = PKDrawing()
    }
    canvasView.isInstallingDrawing = true
    canvasView.drawing = displayed
    canvasView.isInstallingDrawing = false
  }

  func canonicalDrawing(from displayed: PKDrawing,
                        using transform: CGAffineTransform) -> PKDrawing {
    return displayed.transformed(using: transform.inverted())
  }

  func sameDrawing(_ lhs: PKDrawing, _ rhs: PKDrawing) -> Bool {
    lhs.dataRepresentation() == rhs.dataRepresentation()
  }

  private func installPenAfterDrawing() {
    let pen = queuedPen ?? currentPen
    self.queuedPen = nil
    installPen(pen)
  }
}
