import Foundation
import PDFKit
import PencilKit
import UIKit

/// Reports layout and pre-dispatch navigation touches without making PDFView's
/// internal hierarchy part of the viewport contract.
final class InkPdfView: PDFView {
  weak var owner: PdfView?

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if event?.allTouches?.contains(where: { $0.phase == .began }) == true {
      owner?.documentViewNavigationTouchBegan(self)
    }
    return super.hitTest(point, with: event)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    owner?.documentViewLayoutChanged(self)
  }
}

/// PencilKit owns live iOS input and presentation. The coordinator observes
/// the PencilKit lifecycle callbacks and waits for the final drawing-change
/// delivery before storing a native snapshot.
final class InkCanvasView: PKCanvasView {
  weak var owner: PdfView?
  private var activeTransactionID: UInt64?
  private var isResettingInteraction = false
  var isInstallingDrawing = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    backgroundColor = .clear
    isOpaque = false
    isMultipleTouchEnabled = false
    isScrollEnabled = false
    drawingPolicy = .anyInput
    overrideUserInterfaceStyle = .light
    drawingGestureRecognizer.addTarget(self,
                                       action: #selector(drawingGestureDidChange(_:)))
  }

  deinit {
    drawingGestureRecognizer.removeTarget(self,
                                          action: #selector(drawingGestureDidChange(_:)))
  }

  /// The custom snapshot stacks are the only history authority. Returning
  /// nil prevents PencilKit/UIKit from mutating the displayed drawing through
  /// a competing native undo manager.
  override var undoManager: UndoManager? {
    nil
  }

  func cancelDrawingInteraction() {
    activeTransactionID = nil
    isResettingInteraction = true
    drawingGestureRecognizer.isEnabled = false
    drawingGestureRecognizer.isEnabled = true
    isResettingInteraction = false
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    if owner?.editMode == false, hit === self { return nil }
    return hit
  }

  @objc private func drawingGestureDidChange(_ gestureRecognizer: UIGestureRecognizer) {
    guard !isResettingInteraction,
          gestureRecognizer === drawingGestureRecognizer else { return }
    switch gestureRecognizer.state {
    case .began:
      guard activeTransactionID == nil else { return }
      guard let transactionID = owner?.canvasGestureWillBegin(self) else {
        // A previous ended interaction may still own a delayed PencilKit
        // revision. Do not let this gesture mutate that live drawing while it
        // is waiting for its owner callback.
        cancelDrawingInteraction()
        return
      }
      activeTransactionID = transactionID
    case .ended:
      activeTransactionID = nil
    case .cancelled, .failed:
      guard let transactionID = activeTransactionID else { return }
      activeTransactionID = nil
      owner?.canvasDidCancelDrawing(self, transactionID: transactionID)
    default:
      break
    }
  }
}

/// Retained because PDFView.pageOverlayViewProvider is weak.
final class PageOverlayProvider: NSObject, PDFPageOverlayViewProvider {
  weak var owner: PdfView?
  let canvasView = InkCanvasView()

  override init() {
    super.init()
    canvasView.isUserInteractionEnabled = false
  }

  func pdfView(_: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    guard let owner, owner.isSupportedPage(page) else { return nil }
    return canvasView
  }

  func pdfView(_: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
    guard let owner, overlayView === canvasView else { return }
    owner.overlayDidDisplay(canvasView, for: page)
  }

  func pdfView(_: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
    guard let owner, overlayView === canvasView else { return }
    owner.overlayDidEndDisplaying(canvasView, for: page)
  }
}
