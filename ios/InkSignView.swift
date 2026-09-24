import Foundation
import CoreGraphics
import PencilKit
import UIKit
import NitroModules

/// Native implementation backing the generated HybridInkSignViewSpec.
/// PDF, PencilKit input, history, and callbacks are main-thread owned. PDF
/// parsing and export are isolated on serial queues.
final class InkSignPdfGestureRecognizerDelegate: NSObject, UIGestureRecognizerDelegate {
  weak var owner: InkSignView?

  init(owner: InkSignView) {
    self.owner = owner
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    owner?.gestureRecognizer(gestureRecognizer, shouldReceive: touch) ?? false
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    owner?.gestureRecognizer(
      gestureRecognizer,
      shouldRecognizeSimultaneouslyWith: otherGestureRecognizer
    ) ?? false
  }
}

final class InkSignPdfCanvasViewDelegate: NSObject, PKCanvasViewDelegate {
  weak var owner: InkSignView?

  init(owner: InkSignView) {
    self.owner = owner
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    owner?.canvasViewDrawingDidChange(canvasView)
  }

  func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
    owner?.canvasViewDidBeginUsingTool(canvasView)
  }

  func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
    owner?.canvasViewDidEndUsingTool(canvasView)
  }
}

final class InkSignView: HybridInkSignViewSpec {
  struct PendingOpen {
    let token: UInt64
    let operation: InkSignPdfDocumentCoordinator.OperationToken?
    let promise: Promise<PageInfo>
    let zoom: Double?
    let focus: CGPoint?
    let fitToPage: Bool
    var previousViewport: ViewportTarget? = nil
    var previousEditing: Bool = false
  }

  let container = UIView()
  let documentView = InkPdfView()
  let overlayProvider = PageOverlayProvider()
  let artifactPolicy = InkSignPdfCacheArtifactPolicy.shared
  lazy var pageInputCoordinator = InkSignPdfPageInputCoordinator(
    hostView: container,
    artifactPolicy: artifactPolicy)
  private lazy var gestureRecognizerDelegate = InkSignPdfGestureRecognizerDelegate(owner: self)
  private lazy var canvasViewDelegate = InkSignPdfCanvasViewDelegate(owner: self)
  private let pageTurnPreviewScheduler: InkSignPdfPageTurnPreviewScheduler
  private let pageTurnAnimationDriverFactory: InkSignPdfPageTurnAnimationDriverFactory
  lazy var pageTurnLifecycle = InkSignPdfPageTurnLifecycle(
    owner: self,
    previewScheduler: pageTurnPreviewScheduler,
    animationDriverFactory: pageTurnAnimationDriverFactory)

  let documentCoordinator: InkSignPdfDocumentCoordinator
  lazy var textInteractionOverlay = InkSignPdfTextInteractionOverlay(frame: .zero)
  var viewportRequestID: UInt64 = 0
  var pageSwitchRequestID: UInt64 = 0
  var pageNavigationRequestID: UInt64 = 0
  var pendingPageSwitchID: UInt64?
  var pendingPageSwitchEditing = false
  var pendingPageSwitchCompletion: ((Result<PageInfo, Error>) -> Void)?
  var viewportAnimation: ViewportAnimationDriver?
  var textKeyboardOcclusion: CGFloat = 0
  var pendingOpen: PendingOpen?
  var editMode = false
  var doubleTap: DoubleTapOptions?
  var currentPen = PenValue()
  var queuedPen: PenValue?
  var activeDrawingBaseline: InkSignPdfPageContentSnapshot?
  var activeDrawingPageToOverlayTransform: CGAffineTransform?
  var activeDrawingTransactionID: UInt64?
  var pendingDrawingTransactionID: UInt64?
  var endedDrawingBaseline: InkSignPdfPageContentSnapshot?
  var endedDrawingPageToOverlayTransform: CGAffineTransform?
  var endedDrawingTransactionID: UInt64?
  var nextDrawingTransactionID: UInt64 = 0
  var nextTextAnnotationID: UInt64 = 0
  var lastChange: (Bool, Bool, Bool, String)?
  var backgroundObserver: NSObjectProtocol?
  var overlayTransformPage: UUID?
  var attachedOverlayPage: UUID?
  var overlayTransformBounds = CGRect.zero
  var overlayTransformMediaBox = CGRect.zero
  var overlayTransformViewportFrame = CGRect.zero
  var pageToOverlayTransform: CGAffineTransform?
  var disposed = false

  var view: UIView { container }

  lazy var doubleTapGestureRecognizer: UITapGestureRecognizer = {
    let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    recognizer.numberOfTapsRequired = 2
    recognizer.delegate = gestureRecognizerDelegate
    recognizer.cancelsTouchesInView = true
    return recognizer
  }()

  lazy var edgeNavigationGestureRecognizer: UIPanGestureRecognizer = {
    let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleEdgeNavigationPan(_:)))
    recognizer.delegate = gestureRecognizerDelegate
    recognizer.cancelsTouchesInView = false
    recognizer.maximumNumberOfTouches = 1
    return recognizer
  }()

  // Shared Nitro property; Android PDFium consumes this font configuration.
  var fallbackFont: PdfFallbackFont?
  var strokeColor: String? { didSet { updatePenConfiguration() } }
  var strokeMinWidth: Double?
  var strokeMaxWidth: Double? { didSet { updatePenConfiguration() } }
  var strokeSmoothing: Double?
  var defaultTextFontSize: Double? {
    didSet { textInteractionOverlay.setDefaultFontSize(defaultTextFontSize) }
  }
  var defaultTextColor: String? {
    didSet { textInteractionOverlay.setDefaultTextColor(defaultTextColor) }
  }
  var outlineColor: String? {
    didSet { textInteractionOverlay.setOutlineColor(outlineColor) }
  }
  var selectedOutlineColor: String? {
    didSet { textInteractionOverlay.setSelectedOutlineColor(selectedOutlineColor) }
  }
  var editorBackgroundColor: String? {
    didSet { textInteractionOverlay.setEditorBackgroundColor(editorBackgroundColor) }
  }
  var selectedBackgroundColor: String? {
    didSet { textInteractionOverlay.setSelectedBackgroundColor(selectedBackgroundColor) }
  }
  var keyboardAvoidanceEnabled: Bool? {
    didSet { textInteractionOverlay.setKeyboardAvoidanceEnabled(keyboardAvoidanceEnabled != false) }
  }

  var onStateChange: ((StateChangeEvent) -> Void)?
  var onPageChange: ((PageInfo) -> Void)?

  var canvasView: InkCanvasView { overlayProvider.canvasView }

  init(
    previewScheduler: InkSignPdfPageTurnPreviewScheduler = InkSignPdfDispatchPreviewScheduler(),
    animationDriverFactory: InkSignPdfPageTurnAnimationDriverFactory = ViewportAnimationDriverFactory()
  ) {
    pageTurnPreviewScheduler = previewScheduler
    pageTurnAnimationDriverFactory = animationDriverFactory
    documentCoordinator = InkSignPdfDocumentCoordinator(artifactPolicy: artifactPolicy)
    super.init()
    container.clipsToBounds = true
    documentView.owner = self
    documentView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(pageTurnLifecycle.previewView)
    container.addSubview(documentView)
    NSLayoutConstraint.activate([
      documentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      documentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      documentView.topAnchor.constraint(equalTo: container.topAnchor),
      documentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    documentView.addSubview(overlayProvider.overlayView)
    overlayProvider.overlayView.frame = documentView.bounds
    overlayProvider.overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    pageTurnLifecycle.previewView.frame = container.bounds
    pageTurnLifecycle.previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    documentView.backgroundColor = .clear
    documentView.addGestureRecognizer(doubleTapGestureRecognizer)
    documentView.addGestureRecognizer(edgeNavigationGestureRecognizer)
    documentView.addGestureRecognizer(textInteractionOverlay.placementTapRecognizer)
    configureDoubleTapGestureRecognition()
    configureTextPlacementGestureRecognition()
    overlayProvider.owner = self
    canvasView.owner = self
    textInteractionOverlay.owner = self
    textInteractionOverlay.onInteractionModeChanged = { [weak self] in
      self?.emitChange()
    }
    textInteractionOverlay.frame = canvasView.bounds
    textInteractionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    canvasView.addSubview(textInteractionOverlay)
    canvasView.delegate = canvasViewDelegate
    installPen(currentPen)
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main) { [weak self] _ in
        self?.cancelActiveStroke()
      }
    setInteractionMode(editing: false)
  }

  deinit {
    pageTurnLifecycle.dispose()
    viewportAnimation?.stop()
    pendingOpen = nil
    disposed = true
    documentCoordinator.dispose()
    pageNavigationRequestID &+= 1
    overlayProvider.owner = nil
    canvasView.owner = nil
    textInteractionOverlay.dispose()
    canvasView.delegate = nil
    if let backgroundObserver {
      NotificationCenter.default.removeObserver(backgroundObserver)
    }
  }

  func dispose() {
    performOnMain {
      guard !self.disposed else { return }
      self.pageInputCoordinator.cancelPending()
      self.cancelPendingPageSwitch()
      self.disposed = true
      self.documentCoordinator.dispose()
      self.viewportRequestID &+= 1
      self.pageSwitchRequestID &+= 1
      self.pageNavigationRequestID &+= 1
      self.viewportAnimation?.stop()
      self.viewportAnimation = nil
      let pendingOpen = self.pendingOpen
      self.pendingOpen = nil
      self.pageTurnLifecycle.dispose()
      pendingOpen?.promise.reject(withError: LoadError.cancelled)
      self.textInteractionOverlay.finishForLifecycle()
      self.cancelActiveStroke(clearLive: false)
      self.documentView.removePage()
      self.setInteractionMode(editing: false, interactionsEnabled: false)
      self.attachedOverlayPage = nil
      self.invalidateOverlayTransformCache()
      self.activeDrawingBaseline = nil
      self.pendingDrawingTransactionID = nil
      self.endedDrawingBaseline = nil
      self.overlayProvider.owner = nil
      self.canvasView.owner = nil
      self.textInteractionOverlay.dispose()
      self.canvasView.delegate = nil
      self.canvasView.drawing = PKDrawing()
      if let observer = self.backgroundObserver {
        NotificationCenter.default.removeObserver(observer)
        self.backgroundObserver = nil
      }
      self.onStateChange = nil
      self.onPageChange = nil
    }
  }

  /// Nitro calls this when the native view is removed from the Fabric tree.
  /// Do not wait for HybridObject disposal: the UIKit view and worker queues
  /// can otherwise retain the document and callbacks after unmount.
  func onDropView() {
    dispose()
  }

  enum LoadError: LocalizedError {
    case invalidSourcePath
    case pdfLoadFailed
    case unsupportedPdf
    case cancelled
    case operationInProgress

    var errorDescription: String? {
      switch self {
      case .invalidSourcePath: return "invalid_source_path: Unable to read the PDF"
      case .pdfLoadFailed: return "pdf_load_failed: Unable to load the PDF"
      case .unsupportedPdf: return "unsupported_pdf: The PDF is not supported"
      case .cancelled: return "operation_cancelled: PDF loading was cancelled"
      case .operationInProgress: return "operation_in_progress: Another document operation is active"
      }
    }
  }

  enum ExportError: LocalizedError {
    case notReady
    case invalidOutput
    case cancelled
    case unsupportedContent
    case failed
    case operationInProgress

    var errorDescription: String? {
      switch self {
      case .notReady: return "view_not_ready: The PDF is not ready"
      case .invalidOutput: return "invalid_output_path: The export path is invalid"
      case .cancelled: return "operation_cancelled: PDF export was cancelled"
      case .unsupportedContent: return "pdf_export_unsupported_content: The committed drawing uses unsupported ink"
      case .failed: return "pdf_export_failed: Unable to export the PDF"
      case .operationInProgress: return "operation_in_progress: Another document operation is active"
      }
    }
  }

  enum ViewportError: LocalizedError {
    case invalidOptions(String)
    case notReady
    case cancelled

    var errorDescription: String? {
      switch self {
      case .invalidOptions(let message): return "invalid_viewport: \(message)"
      case .notReady: return "view_not_ready: The PDF view is not ready for a mode transition"
      case .cancelled: return "operation_cancelled: The PDF view was disposed or superseded"
      }
    }
  }

  enum TextError: LocalizedError {
    case notReady
    case notFocused
    case cancelled

    var errorDescription: String? {
      switch self {
      case .notReady:
        return "view_not_ready: The PDF view is not ready for text interaction"
      case .notFocused:
        return "text_not_focused: No text annotation is selected"
      case .cancelled:
        return "operation_cancelled: The text request was disposed or superseded"
      }
    }
  }
}
