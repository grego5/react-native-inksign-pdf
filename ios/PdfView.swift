import Foundation
import CoreGraphics
import PDFKit
import PencilKit
import UIKit
import NitroModules

/// Native implementation backing the generated HybridPdfViewSpec.
/// PDF, PencilKit input, history, and callbacks are main-thread owned. PDF
/// parsing and export are isolated on serial queues.
final class PdfView: HybridPdfViewSpec, UIGestureRecognizerDelegate {
  struct PendingOpen {
    let token: UInt64
    let promise: Promise<PageInfo>
    let zoom: Double?
    let focus: CGPoint?
    let fitToPage: Bool
  }

  let container = UIView()
  let documentView = InkPdfView()
  let overlayProvider = PageOverlayProvider()
  let loadQueue = DispatchQueue(label: "ReactNativeInkSignPdf.load", qos: .userInitiated)
  let exportQueue = DispatchQueue(label: "ReactNativeInkSignPdf.export", qos: .userInitiated)
  let publicationLock = NSLock()
  let artifactPolicy = InkSignPdfCacheArtifactPolicy.shared
  private let pageTurnPreviewScheduler: InkSignPdfPageTurnPreviewScheduler
  private let pageTurnAnimationDriverFactory: InkSignPdfPageTurnAnimationDriverFactory
  lazy var pageTurnLifecycle = InkSignPdfPageTurnLifecycle(
    owner: self,
    previewScheduler: pageTurnPreviewScheduler,
    animationDriverFactory: pageTurnAnimationDriverFactory)

  var documentState: InkSignPdfDocumentState?
  lazy var textInteractionOverlay = InkSignPdfTextInteractionOverlay(frame: .zero)
  var generation: UInt64 = 0
  var viewportRequestID: UInt64 = 0
  var pageSwitchRequestID: UInt64 = 0
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
  var activeDrawingTransactionID: UInt64?
  var pendingDrawingTransactionID: UInt64?
  var endedDrawingBaseline: InkSignPdfPageContentSnapshot?
  var endedDrawingTransactionID: UInt64?
  var nextDrawingTransactionID: UInt64 = 0
  var nextTextAnnotationID: UInt64 = 0
  var lastChange: (Bool, Bool, Bool, String)?
  var backgroundObserver: NSObjectProtocol?
  weak var overlayTransformPage: PDFPage?
  weak var attachedOverlayPage: PDFPage?
  var overlayTransformBounds = CGRect.zero
  var overlayTransformMediaBox = CGRect.zero
  var pageToOverlayTransform: CGAffineTransform?
  var disposed = false
  var pendingOutputURLs = Set<URL>()
  var ownedOutputURLs = Set<URL>()

  var view: UIView { container }

  lazy var doubleTapGestureRecognizer: UITapGestureRecognizer = {
    let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    recognizer.numberOfTapsRequired = 2
    recognizer.delegate = self
    recognizer.cancelsTouchesInView = true
    return recognizer
  }()

  lazy var edgeNavigationGestureRecognizer: UIPanGestureRecognizer = {
    let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleEdgeNavigationPan(_:)))
    recognizer.delegate = self
    recognizer.cancelsTouchesInView = false
    recognizer.maximumNumberOfTouches = 1
    return recognizer
  }()

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
    pageTurnLifecycle.previewView.frame = container.bounds
    pageTurnLifecycle.previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    documentView.displayMode = .singlePage
    documentView.displayDirection = .vertical
    documentView.displayBox = .mediaBox
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
    canvasView.delegate = self
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
    publicationLock.lock()
    disposed = true
    generation &+= 1
    let outputs = pendingOutputURLs.union(ownedOutputURLs)
    pendingOutputURLs.removeAll()
    ownedOutputURLs.removeAll()
    publicationLock.unlock()
    let policy = artifactPolicy
    exportQueue.async {
      outputs.forEach(policy.deleteExact)
    }
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
      self.cancelPendingPageSwitch()
      self.publicationLock.lock()
      self.disposed = true
      self.generation &+= 1
      self.viewportRequestID &+= 1
      self.pageSwitchRequestID &+= 1
      self.viewportAnimation?.stop()
      self.viewportAnimation = nil
      let pendingOpen = self.pendingOpen
      self.pendingOpen = nil
      self.pageTurnLifecycle.dispose()
      self.edgeNavigationGestureRecognizer.isEnabled = false
      self.publicationLock.unlock()
      pendingOpen?.promise.reject(withError: LoadError.cancelled)
      self.textInteractionOverlay.finishForLifecycle()
      self.cancelActiveStroke(clearLive: false)
      self.documentView.pageOverlayViewProvider = nil
      self.documentView.document = nil
      self.documentState = nil
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
      self.publicationLock.lock()
      let outputs = self.pendingOutputURLs.union(self.ownedOutputURLs)
      self.pendingOutputURLs.removeAll()
      self.ownedOutputURLs.removeAll()
      self.publicationLock.unlock()
      let policy = self.artifactPolicy
      self.exportQueue.async {
        outputs.forEach(policy.deleteExact)
      }
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

    var errorDescription: String? {
      switch self {
      case .invalidSourcePath: return "invalid_source_path: Unable to read the PDF"
      case .pdfLoadFailed: return "pdf_load_failed: Unable to load the PDF"
      case .unsupportedPdf: return "unsupported_pdf: The PDF is not supported"
      case .cancelled: return "operation_cancelled: PDF loading was cancelled"
      }
    }
  }

  enum ExportError: LocalizedError {
    case notReady
    case invalidOutput
    case cancelled
    case failed

    var errorDescription: String? {
      switch self {
      case .notReady: return "view_not_ready: The PDF is not ready"
      case .invalidOutput: return "invalid_output_path: The export path is invalid"
      case .cancelled: return "operation_cancelled: PDF export was cancelled"
      case .failed: return "pdf_export_failed: Unable to export the PDF"
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
