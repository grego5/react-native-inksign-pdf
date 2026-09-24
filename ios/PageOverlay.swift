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

/// PDFKit sizes and rotates this transparent layer with its page.
final class InkSignPdfPageOverlayView: UIView {
  weak var owner: InkSignView?
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

  override func layoutSubviews() {
    super.layoutSubviews()
    owner?.overlayLayoutChanged(canvasView)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    if hit === self { return nil }
    return hit
  }
}

/// Supplies one PencilKit surface per PDFPage while committed page content
/// remains owned by the document coordinator.
final class PageOverlayProvider: NSObject, PDFPageOverlayViewProvider {
  weak var owner: InkSignView? {
    didSet {
      fallbackOverlay.owner = owner
      if let owner {
        owner.configureCanvasView(fallbackOverlay.canvasView)
      } else {
        fallbackOverlay.canvasView.owner = nil
        fallbackOverlay.canvasView.delegate = nil
      }
      for overlay in overlays.values {
        overlay.owner = owner
        if let owner {
          owner.configureCanvasView(overlay.canvasView)
        } else {
          overlay.canvasView.owner = nil
          overlay.canvasView.delegate = nil
        }
      }
    }
  }
  private let fallbackOverlay = InkSignPdfPageOverlayView()
  private var overlays: [ObjectIdentifier: InkSignPdfPageOverlayView] = [:]
  private var displayedPages = Set<ObjectIdentifier>()
  private var documentIdentity: ObjectIdentifier?
  private var generation: UInt64?

  var overlayView: InkSignPdfPageOverlayView {
    guard let page = owner?.documentCoordinator.document?.activePage.page else {
      return fallbackOverlay
    }
    return overlay(for: page)
  }

  var canvasView: InkCanvasView { overlayView.canvasView }

  override init() {
    super.init()
    canvasView.isUserInteractionEnabled = false
  }

  func install(document: PDFDocument, generation: UInt64) {
    let identity = ObjectIdentifier(document)
    guard documentIdentity != identity || self.generation != generation else { return }
    reset()
    documentIdentity = identity
    self.generation = generation
  }

  func reset() {
    owner?.overlayProviderWillReset()
    for overlay in overlays.values {
      overlay.owner = nil
      overlay.canvasView.owner = nil
      overlay.canvasView.delegate = nil
      overlay.removeFromSuperview()
    }
    overlays.removeAll()
    displayedPages.removeAll()
    documentIdentity = nil
    generation = nil
  }

  func canvasView(for pageID: UUID) -> InkCanvasView? {
    guard let page = owner?.documentCoordinator.document?.pages.first(where: { $0.id == pageID })?.page else {
      return nil
    }
    return overlay(for: page).canvasView
  }

  func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    overlay(for: page)
  }

  func pdfView(_ view: PDFView,
               willDisplayOverlayView overlayView: UIView,
               for page: PDFPage) {
    guard let overlay = overlayView as? InkSignPdfPageOverlayView,
          let pageID = pageID(for: page) else { return }
    displayedPages.insert(ObjectIdentifier(page))
    owner?.configureDoubleTapGestureRecognition()
    owner?.configureTextPlacementGestureRecognition()
    owner?.overlayDidDisplay(overlay.canvasView, for: pageID)
    owner?.updatePDFViewInteractionOwnership()
  }

  func pdfView(_ view: PDFView,
               willEndDisplayingOverlayView overlayView: UIView,
               for page: PDFPage) {
    displayedPages.remove(ObjectIdentifier(page))
    guard let overlay = overlayView as? InkSignPdfPageOverlayView,
          let pageID = pageID(for: page) else { return }
    owner?.overlayDidEndDisplaying(overlay.canvasView, for: pageID)
    guard overlays[ObjectIdentifier(page)] === overlay else { return }
    overlays.removeValue(forKey: ObjectIdentifier(page))
    overlay.owner = nil
    overlay.canvasView.owner = nil
    overlay.canvasView.delegate = nil
  }

  func isDisplaying(_ page: PDFPage) -> Bool {
    displayedPages.contains(ObjectIdentifier(page))
  }

  private func overlay(for page: PDFPage) -> InkSignPdfPageOverlayView {
    let key = ObjectIdentifier(page)
    if let overlay = overlays[key] { return overlay }
    let overlay = InkSignPdfPageOverlayView()
    overlay.owner = owner
    owner?.configureCanvasView(overlay.canvasView)
    overlays[key] = overlay
    return overlay
  }

  private func pageID(for page: PDFPage) -> UUID? {
    guard let state = owner?.documentCoordinator.document else { return nil }
    let index = state.document.index(for: page)
    guard index >= 0, index < state.pages.count else { return nil }
    return state.pages[index].id
  }
}
