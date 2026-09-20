import Foundation
import PDFKit
import PencilKit
import UIKit

/// PencilKit owns live iOS input and presentation. The coordinator observes
/// the PencilKit lifecycle callbacks and waits for the final drawing-change
/// delivery before storing a native snapshot.
final class InkCanvasView: PKCanvasView {
  weak var owner: InkSignView?
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

/// The transparent annotation layer is retained independently of the base page
/// renderer. PencilKit and the text editor remain owned by the stable canvas
/// accessor.
final class InkSignPdfPageOverlayView: UIView {
  let canvasView = InkCanvasView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    canvasView.frame = bounds
    canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(canvasView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    if hit === self { return nil }
    return hit
  }
}

/// Retained because the page host owns the overlay independently of PDFKit.
final class PageOverlayProvider: NSObject {
  weak var owner: InkSignView?
  let overlayView = InkSignPdfPageOverlayView()

  var canvasView: InkCanvasView { overlayView.canvasView }

  override init() {
    super.init()
    canvasView.isUserInteractionEnabled = false
  }
}
