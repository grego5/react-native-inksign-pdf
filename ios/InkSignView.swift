import Foundation
import CoreGraphics
import PDFKit
import PencilKit
import UIKit
import NitroModules

/// Native implementation backing the generated HybridInkSignViewSpec.
/// PDF, PencilKit input, history, and callbacks are main-thread owned. PDF
/// parsing and export are isolated on serial queues.
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

final class InkSignPdfViewGestureDelegate: NSObject, UIGestureRecognizerDelegate {
  weak var owner: InkSignView?

  init(owner: InkSignView) {
    self.owner = owner
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldReceive touch: UITouch) -> Bool {
    if let owner, gestureRecognizer === owner.coordinateTapGestureRecognizer {
      return owner.isPickingPageCoords
    }
    if owner?.isPickingPageCoords == true { return false }
    guard let owner,
          gestureRecognizer === owner.doubleTapGestureRecognizer,
          let target = touch.view,
          target === owner.textInteractionOverlay ||
            target.isDescendant(of: owner.textInteractionOverlay) else { return true }
    return false
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }
}

final class InkSignView: HybridInkSignViewSpec {
  struct PendingOpen {
    enum Phase: Equatable {
      case preparing
      case installing
      case awaitingReadiness
      case completing
      case clearing

      var suppressesPresentationCallbacks: Bool {
        self != .preparing
      }
    }

    let operation: InkSignPdfDocumentCoordinator.OperationToken
    let settlement: InkSignPdfOperationPromise<PageInfo>
    let zoom: Double?
    let focus: CGPoint?
    let fitToPage: Bool
    var phase: Phase = .preparing

    init(operation: InkSignPdfDocumentCoordinator.OperationToken,
         promise: Promise<PageInfo>, zoom: Double?, focus: CGPoint?, fitToPage: Bool,
         phase: Phase = .preparing) {
      self.operation = operation
      self.settlement = InkSignPdfOperationPromise(promise: promise)
      self.zoom = zoom
      self.focus = focus
      self.fitToPage = fitToPage
      self.phase = phase
    }
  }

  let container = UIView()
  let documentView = PDFView()
  let pdfViewInteractionOwnership = PDFViewInteractionOwnership()
  let overlayProvider = PageOverlayProvider()
  let artifactPolicy = InkSignPdfCacheArtifactPolicy.shared
  lazy var pageInputCoordinator = InkSignPdfPageInputCoordinator(
    hostView: container,
    artifactPolicy: artifactPolicy)
  private lazy var canvasViewDelegate = InkSignPdfCanvasViewDelegate(owner: self)
  let documentCoordinator: InkSignPdfDocumentCoordinator
  lazy var textInteractionOverlay = InkSignPdfTextInteractionOverlay(frame: .zero)
  private lazy var pdfViewGestureDelegate = InkSignPdfViewGestureDelegate(owner: self)
  var pageSwitchRequestID: UInt64 = 0
  var fieldFocusRequestID: UInt64 = 0
  let viewportMotion = InkSignPdfViewportMotion()
  var isApplyingViewportFrame = false
  var pageNavigationRequestID: UInt64 = 0
  var pendingPageSwitchID: UInt64?
  var pendingPageSwitchEditing = false
  var pendingPageSwitchViewport: ViewportRequest?
  var pendingStructuralPresentationPageID: UUID?
  var pendingPageSwitchCompletion: ((Result<PageInfo, Error>) -> Void)?
  var textKeyboardOcclusion: CGFloat = 0
  weak var textInsetScrollView: UIScrollView?
  var textInsetAdjustment: (baseBottom: CGFloat, appliedBottom: CGFloat)?
  var pendingOpen: PendingOpen?
  var editMode = false
  var viewInteractionsEnabled = true
  var structuralInteractionSuspended = false
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
  var lastChange: (Bool, Bool, Bool, String, String?, String?)?
  var documentID: String?
  var loadError: String?
  struct CoordinateTarget {
    let generation: UInt64
    let pageID: UUID
    let geometryRevision: UInt64
  }
  final class CoordinateRequest {
    let result = InkSignPdfOperationPromise<PageCoords>()
    var target: CoordinateTarget?
    var modeSession: InkSignPdfModeSessionToken?
  }
  var pendingPageCoords: CoordinateRequest?
  var currentModeSession: InkSignPdfModeSessionToken?
  var isPickingPageCoords: Bool { pendingPageCoords?.target != nil }

  func interactionMode() -> InteractionMode {
    isPickingPageCoords ? .pagecoords : textInteractionOverlay.interactionMode()
  }
  var commandQueue: [ViewerCommand] = []
  var runningCommand: ViewerCommand?

  struct ViewerCommand {
    let id: UUID
    let presentation: Bool
    let modeSession: InkSignPdfModeSessionToken?
    let start: () -> Void
    let cancel: () -> Void
  }
  var backgroundObserver: NSObjectProtocol?
  var pdfPageObserver: NSObjectProtocol?
  var pdfScaleObserver: NSObjectProtocol?
  var overlayTransformPage: UUID?
  var attachedOverlayPage: UUID?
  var overlayTransformBounds = CGRect.zero
  var overlayTransformMediaBox = CGRect.zero
  var pageToOverlayTransform: CGAffineTransform?
  var disposed = false

  var suppressesOpenPresentationCallbacks: Bool {
    pendingOpen?.phase.suppressesPresentationCallbacks ?? false
  }

  var view: UIView { container }

  lazy var doubleTapGestureRecognizer: UITapGestureRecognizer = {
    let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    recognizer.numberOfTapsRequired = 2
    recognizer.delegate = pdfViewGestureDelegate
    recognizer.cancelsTouchesInView = true
    return recognizer
  }()

  lazy var coordinateTapGestureRecognizer: UITapGestureRecognizer = {
    let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleCoordinateTap(_:)))
    recognizer.delegate = pdfViewGestureDelegate
    recognizer.cancelsTouchesInView = true
    recognizer.isEnabled = false
    return recognizer
  }()

  // Shared Nitro property; Android PDFium consumes this font configuration.
  var androidFallbackFont: AndroidFallbackFont?
  var strokeColor: String? {
    didSet { enqueueNativeConfiguration(.pen(color: strokeColor, maxWidth: strokeMaxWidth)) }
  }
  var strokeMinWidth: Double?
  var strokeMaxWidth: Double? {
    didSet { enqueueNativeConfiguration(.pen(color: strokeColor, maxWidth: strokeMaxWidth)) }
  }
  var strokeSmoothing: Double?
  var defaultTextFontSize: Double? {
    didSet { enqueueNativeConfiguration(.defaultTextFontSize(defaultTextFontSize)) }
  }
  var defaultTextColor: String? {
    didSet { enqueueNativeConfiguration(.defaultTextColor(defaultTextColor)) }
  }
  var outlineColor: String? {
    didSet { enqueueNativeConfiguration(.outlineColor(outlineColor)) }
  }
  var selectedOutlineColor: String? {
    didSet { enqueueNativeConfiguration(.selectedOutlineColor(selectedOutlineColor)) }
  }
  var editorBackgroundColor: String? {
    didSet { enqueueNativeConfiguration(.editorBackgroundColor(editorBackgroundColor)) }
  }
  var selectedBackgroundColor: String? {
    didSet { enqueueNativeConfiguration(.selectedBackgroundColor(selectedBackgroundColor)) }
  }
  var keyboardAvoidanceEnabled: Bool? {
    didSet { enqueueNativeConfiguration(.keyboardAvoidanceEnabled(keyboardAvoidanceEnabled != false)) }
  }
  var pagerDirection: PagerDirection? {
    didSet { applyPagerDirection() }
  }

  var onStateChange: ((ViewerState) -> Void)? {
    didSet { performOnMain { self.emitChange(force: true) } }
  }
  var onPageChange: ((PageInfo) -> Void)?
  var onZoomChange: ((Double) -> Void)?
  private var zoomReportWork: DispatchWorkItem?
  private var zoomReportSample: (UUID, CGFloat, CGFloat)?
  private var reportedZoomGeneration: UInt64?
  private var reportedZoomPage: UUID?
  private var reportedZoom: Double?

  func scheduleZoomReport() {
    guard !disposed, let state = documentCoordinator.document,
          let fit = usableFitScale() else { return }
    let sample = (state.activePage.id, documentView.scaleFactor, fit)
    if let previous = zoomReportSample, previous == sample,
       reportedZoomGeneration == documentCoordinator.generation,
       reportedZoomPage == state.activePage.id,
       reportedZoom == Double(sample.1 / sample.2) { return }
    zoomReportSample = sample
    zoomReportWork?.cancel()
    queueZoomReport()
  }

  private func queueZoomReport() {
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.disposed, let state = self.documentCoordinator.document else { return }
      if self.viewportMotion.isRunning || self.hasActiveViewportGesture(in: self.documentView) {
        self.queueZoomReport()
        return
      }
      guard let fit = self.usableFitScale() else { return }
      guard self.documentView.currentPage === state.activePage.page,
            self.attachedOverlayPage == state.activePage.id,
            self.pageToOverlayTransform != nil else { return }
      let zoom = Double(self.documentView.scaleFactor / fit)
      if self.reportedZoomGeneration != self.documentCoordinator.generation ||
         self.reportedZoomPage != state.activePage.id || self.reportedZoom != zoom {
        self.reportedZoomGeneration = self.documentCoordinator.generation
        self.reportedZoomPage = state.activePage.id
        self.reportedZoom = zoom
        self.onZoomChange?(zoom)
      }
      self.zoomReportSample = (state.activePage.id, self.documentView.scaleFactor, fit)
    }
    zoomReportWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
  }

  private func hasActiveViewportGesture(in view: UIView) -> Bool {
    if let scroll = view as? UIScrollView,
       scroll.isTracking || scroll.isDragging || scroll.isDecelerating || scroll.isZooming || scroll.isZoomBouncing {
      return true
    }
    return view.subviews.contains { hasActiveViewportGesture(in: $0) }
  }
  var onTextSelectionChange: ((Variant_NullType_TextSelection?) -> Void)?

  var canvasView: InkCanvasView { overlayProvider.canvasView }

  func configureCanvasView(_ canvas: InkCanvasView) {
    canvas.owner = self
    canvas.delegate = canvasViewDelegate
    configureCanvasInteraction(canvas)
    canvas.tool = PKInkingTool(.pen, color: currentPen.color,
                               width: CGFloat(currentPen.maxWidth))
  }

  override init() {
    documentCoordinator = InkSignPdfDocumentCoordinator(artifactPolicy: artifactPolicy)
    super.init()
    container.clipsToBounds = true
    documentView.backgroundColor = .white
    documentView.isOpaque = true
    documentView.displayMode = .singlePage
    documentView.displayDirection = .horizontal
    documentView.usePageViewController(true, withViewOptions: nil)
    applyPagerDirectionNow()
    documentView.displayBox = .mediaBox
    documentView.displaysPageBreaks = false
    documentView.minScaleFactor = 0.1
    documentView.maxScaleFactor = 16
    documentView.autoScales = false
    documentView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(documentView)
    NSLayoutConstraint.activate([
      documentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      documentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      documentView.topAnchor.constraint(equalTo: container.topAnchor),
      documentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    documentView.pageOverlayViewProvider = overlayProvider
    documentView.addGestureRecognizer(doubleTapGestureRecognizer)
    documentView.addGestureRecognizer(coordinateTapGestureRecognizer)
    documentView.addGestureRecognizer(textInteractionOverlay.placementTapRecognizer)
    configureDoubleTapGestureRecognition()
    overlayProvider.owner = self
    canvasView.owner = self
    textInteractionOverlay.owner = self
    textInteractionOverlay.onInteractionModeChanged = { [weak self] in
      self?.emitChange()
    }
    textInteractionOverlay.onTextSelectionChange = { [weak self] selection in
      guard let self else { return }
      self.onTextSelectionChange?(selection.map(Variant_NullType_TextSelection.second) ??
        .first(NullType.null))
    }

    canvasView.delegate = canvasViewDelegate
    installPen(currentPen)
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main) { [weak self] _ in
        self?.cancelActiveStroke()
      }
    setInteractionMode(editing: false)
    pdfPageObserver = NotificationCenter.default.addObserver(
      forName: .PDFViewPageChanged,
      object: documentView,
      queue: .main) { [weak self] _ in self?.documentViewPageDidChange() }
    pdfScaleObserver = NotificationCenter.default.addObserver(
      forName: .PDFViewScaleChanged,
      object: documentView,
      queue: .main) { [weak self] _ in self?.refreshActiveOverlayTransform() }
  }

  deinit {
    disposed = true
    viewportMotion.cancel()
    currentModeSession?.cancelled = true
    pendingPageCoords?.result.reject(LoadError.cancelled)
    pendingPageCoords = nil
    pendingOpen = nil
    pageNavigationRequestID &+= 1
    textInteractionOverlay.discardForDisposal()
    documentView.document = nil
    overlayProvider.dispose()
    documentCoordinator.dispose()
    textInteractionOverlay.dispose()
    if let backgroundObserver {
      NotificationCenter.default.removeObserver(backgroundObserver)
    }
    if let pdfPageObserver { NotificationCenter.default.removeObserver(pdfPageObserver) }
    if let pdfScaleObserver { NotificationCenter.default.removeObserver(pdfScaleObserver) }
  }

  func dispose() {
    performOnMain {
      guard !self.disposed else { return }
      self.invalidateModeSession()
      self.disposed = true
      self.viewportMotion.cancel()
      self.cancelViewerCommands()
      self.pageInputCoordinator.cancelPending()
      self.cancelPendingPageSwitch()
      self.textInteractionOverlay.discardForDisposal()
      self.cancelActiveStroke(clearLive: false)
      let pendingOpen = self.pendingOpen
      self.pendingOpen = nil
      pendingOpen?.settlement.reject(LoadError.cancelled)
      self.pageSwitchRequestID &+= 1
      self.pageNavigationRequestID &+= 1
      self.documentView.document = nil
      self.overlayProvider.dispose()
      self.documentCoordinator.dispose()
      self.applyInteractionMode(editing: false, interactionsEnabled: false)
      self.attachedOverlayPage = nil
      self.invalidateOverlayTransformCache()
      self.activeDrawingBaseline = nil
      self.pendingDrawingTransactionID = nil
      self.endedDrawingBaseline = nil
      self.canvasView.owner = nil
      self.textInteractionOverlay.dispose()
      self.canvasView.delegate = nil
      self.canvasView.drawing = PKDrawing()
      if let observer = self.backgroundObserver {
        NotificationCenter.default.removeObserver(observer)
        self.backgroundObserver = nil
      }
      if let observer = self.pdfPageObserver {
        NotificationCenter.default.removeObserver(observer)
        self.pdfPageObserver = nil
      }
      if let observer = self.pdfScaleObserver {
        NotificationCenter.default.removeObserver(observer)
        self.pdfScaleObserver = nil
      }
      self.onStateChange = nil
      self.onPageChange = nil
      self.zoomReportWork?.cancel()
      self.onZoomChange = nil
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
    case invalidText
    case invalidBounds
    case cancelled
    case keyNotFound
    case ruleNotFound
    case documentNotOpen
    case pageNotFound
    case textNotFound
    case targetAmbiguous
    case textDoesNotFit

    var errorDescription: String? {
      switch self {
      case .notReady:
        return "view_not_ready: The PDF view is not ready for text interaction"
      case .notFocused:
        return "text_not_focused: No text annotation is selected"
      case .invalidText:
        return "invalid_text: Text must not be empty"
      case .invalidBounds:
        return "invalid_text_bounds: Text bounds must define an ordered rectangle inside the active page"
      case .cancelled:
        return "operation_cancelled: The text request was disposed or superseded"
      case .keyNotFound:
        return "text_key_not_found: The requested text key was not found on the active page"
      case .ruleNotFound:
        return "text_rule_not_found: The selected text key has no usable rule or visible line"
      case .documentNotOpen:
        return "document_not_open: A document must be open before acquiring a prepared page"
      case .pageNotFound:
        return "page_not_found: The requested page index is outside the document"
      case .textNotFound:
        return "text_not_found: The text ID does not belong to this page"
      case .targetAmbiguous:
        return "text_target_ambiguous: The source text target is ambiguous"
      case .textDoesNotFit:
        return "text_does_not_fit: The supplied value does not fit in the text target"
      }
    }
  }
}
