import CoreGraphics
import PencilKit
import UIKit

extension InkSignView {
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
    cancelViewportAnimation()
    guard canvasView === self.canvasView,
          editMode, documentState != nil,
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
    activeDrawingBaseline = documentState?.activePage.history.content
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
    endedDrawingBaseline = baseline
    activeDrawingTransactionID = nil
    activeDrawingBaseline = nil
  }

  func canvasGestureWillBegin(_ canvas: InkCanvasView) -> UInt64? {
    guard canvas === canvasView, editMode, documentState != nil,
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
    activeDrawingBaseline = nil
    endedDrawingTransactionID = nil
    endedDrawingBaseline = nil
    if hadInteraction { canvasView.cancelDrawingInteraction() }
    if clearLive { installCommittedDrawing() }
    installQueuedPenIfNeeded()
  }

  /// Stores exactly one history action for an ended interaction. A later
  /// PencilKit revision updates this same transaction before it is cleared;
  /// it can never be attributed to a subsequent active transaction.
  func finishEndedDrawingTransaction(transactionID: UInt64) {
    guard endedDrawingTransactionID == transactionID,
          let baseline = endedDrawingBaseline else { return }
    let finished = canonicalDrawing(from: canvasView.drawing)
    endedDrawingTransactionID = nil
    endedDrawingBaseline = nil
    if sameDrawing(finished, baseline.drawing) {
      installCommittedDrawing()
      installQueuedPenIfNeeded()
      return
    }
    guard let page = documentState?.activePage else { return }
    page.history.record(kind: .ink,
                        before: baseline,
                        after: baseline.replacingDrawing(finished))
    installCommittedDrawing()
    installQueuedPenIfNeeded()
    emitChange()
  }

  var hasDrawingTransaction: Bool {
    pendingDrawingTransactionID != nil ||
      activeDrawingTransactionID != nil || endedDrawingTransactionID != nil
  }

  func installCommittedDrawing() {
    let displayed: PKDrawing
    let committedDrawing = documentState?.activePage.history.content.drawing ?? PKDrawing()
    if let activePage = documentState?.activePage.page,
       attachedOverlayPage === activePage,
       overlayTransformPage === activePage,
       let transform = pageToOverlayTransform {
      displayed = committedDrawing.transformed(using: transform)
    } else {
      displayed = PKDrawing()
    }
    canvasView.isInstallingDrawing = true
    canvasView.drawing = displayed
    canvasView.isInstallingDrawing = false
  }

  func canonicalDrawing(from displayed: PKDrawing) -> PKDrawing {
    guard let transform = pageToOverlayTransform else { return PKDrawing() }
    return displayed.transformed(using: transform.inverted())
  }

  func sameDrawing(_ lhs: PKDrawing, _ rhs: PKDrawing) -> Bool {
    lhs.dataRepresentation() == rhs.dataRepresentation()
  }

  private func installQueuedPenIfNeeded() {
    guard let queuedPen else { return }
    currentPen = queuedPen
    self.queuedPen = nil
    installPen(currentPen)
  }
}
