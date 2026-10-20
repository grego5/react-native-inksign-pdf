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
  weak var owner: ViewerCanvas?

  init(owner: ViewerCanvas) {
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
  weak var owner: ViewerCanvas?

  init(owner: ViewerCanvas) {
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

final class ViewerCanvas: HybridInkSignViewSpec {
  let container = UIView()
  let documentView = PDFView()
  let pdfViewInteractionOwnership = PDFViewInteractionOwnership()
  let overlayProvider = PageOverlayProvider()
  let artifactPolicy = InkSignPdfCacheArtifactPolicy.shared
  private lazy var canvasViewDelegate = InkSignPdfCanvasViewDelegate(owner: self)
  var attachedCore: DocumentCore? { attachedDocument?.core }
  var documentCore: DocumentCore {
    guard let core = attachedCore else {
      preconditionFailure("Document commands require an attached document")
    }
    return core
  }
  func requireDocumentCore() throws -> DocumentCore {
    guard !disposed, let core = attachedCore else { throw TextError.documentNotOpen }
    return core
  }
  private var coreObserver: UUID?
  private let attachmentID = UUID()
  var textDirection: TextDirection? {
    didSet { applyTextDirection() }
  }
  private(set) var attachedDocument: HybridInkSignDocument?
  /// Options that created `attachedDocument`; non-nil means the view owns and closes it.
  private var ownedOptions: DocumentOptions?
  var document: Variant__any_HybridInkSignDocumentSpec__DocumentOptions? {
    get { attachedDocument.map { .first($0) } }
    set {
      performOnMain {
        do { try self.attachDocument(newValue) }
        catch { self.loadError = error.localizedDescription; self.emitChange(force: true) }
      }
    }
  }

  private func attachDocument(_ value: Variant__any_HybridInkSignDocumentSpec__DocumentOptions?) throws {
    guard !disposed else { throw OperationError.cancelled }
    switch value {
    case nil:
      try attach(nil, ownedOptions: nil)
    case .first(let spec)?:
      guard let borrowed = spec as? HybridInkSignDocument else { throw OperationError.cancelled }
      try attach(borrowed, ownedOptions: nil)
    case .second(let options)?:
      if let ownedOptions, ownedOptions.hasSameContent(as: options) { return }
      try attach(HybridInkSignDocument(options: options), ownedOptions: options)
    }
  }

  private func attach(_ next: HybridInkSignDocument?, ownedOptions options: DocumentOptions?) throws {
    if attachedDocument === next { return }
    if let next { try next.core.claimViewer(attachmentID) }
    releaseAttachment(notify: false)
    loadError = next?.core.initializationError?.localizedDescription
    attachedDocument = next
    ownedOptions = options
    guard next != nil else { emitChange(force: true); return }
    textInteractionOverlay.setDefaultFontSize(defaultTextFontSize)
    textInteractionOverlay.setDefaultTextColor(defaultTextColor)
    applyTextDirection()
    coreObserver = documentCore.observe { [weak self] change in self?.documentCoreDidChange(change) }
    guard let state = documentCoordinator.document else { emitChange(force: true); return }
    installStructuralPresentation(state, generation: documentCoordinator.generation,
      viewport: nil, selectedPageID: state.pages.first?.id, fitPage: true,
      completion: structuralPresentationCompletion())
  }

  /// Detaches the current document and closes it when the view owns it.
  func releaseAttachment(commitDraft: Bool = true, notify: Bool = true) {
    let previousDocument = attachedDocument
    let previousCore = attachedCore
    let ownsPrevious = ownedOptions != nil
    defer { withExtendedLifetime(previousDocument) {} }
    if commitDraft && previousCore?.coordinator.document != nil { interaction.finishInteraction() }
    interaction.retireRequests()
    cancelViewerCommands()
    if let coreObserver { previousCore?.removeObserver(coreObserver) }
    coreObserver = nil
    previousCore?.releaseViewer(attachmentID)
    clearPresentation()
    attachedDocument = nil
    ownedOptions = nil
    loadError = nil
    if ownsPrevious, let previousDocument { _ = try? previousDocument.close() }
    if notify { emitChange(force: true) }
  }
  var documentCoordinator: InkSignPdfDocumentCoordinator { documentCore.coordinator }
  var viewerDocument: InkSignPdfViewerDocumentState?
  lazy var textInteractionOverlay = InkSignPdfTextInteractionOverlay(frame: .zero)
  private lazy var pdfViewGestureDelegate = InkSignPdfViewGestureDelegate(owner: self)
  private(set) lazy var interaction = ViewerInteractionCoordinator(host: self)
  var pageNavigationRequestID: UInt64 = 0
  var doubleTap: DoubleTapOptions?
  var currentPen = PenValue()
  var queuedPen: PenValue?
  var activeDrawingBaseline: InkSignPdfPageContentSnapshot?
  var activeDrawingPageToOverlayTransform: CGAffineTransform?
  var activeDrawingTransactionID: UInt64?
  var activeDrawingContext: InkSignPdfCorePageContext?
  var pendingDrawingTransactionID: UInt64?
  var endedDrawingBaseline: InkSignPdfPageContentSnapshot?
  var endedDrawingPageToOverlayTransform: CGAffineTransform?
  var endedDrawingTransactionID: UInt64?
  var endedDrawingContext: InkSignPdfCorePageContext?
  var nextDrawingTransactionID: UInt64 = 0
  var lastChange: (Int, Bool, String, String?, String?, Int?)?
  var lastPublicPage: PageChangeEvent?
  var documentID: String? { attachedCore?.coordinator.documentID }
  var loadError: String?
  var isPickingPageCoords: Bool { interaction.isPickingCoordinates }
  func interactionMode() -> InteractionMode { interaction.mode }
  var commandQueue: [ViewerCommand] = []
  var runningCommand: ViewerCommand?

  struct ViewerCommand {
    let id: UUID
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
  var overlayTransformVisibleBox = CGRect.zero
  var pageToOverlayTransform: CGAffineTransform?
  var disposed = false

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
  var onPageChange: ((PageChangeEvent) -> Void)? {
    didSet {
      performOnMain {
        self.lastPublicPage = nil
        self.emitPageState()
      }
    }
  }
  var onZoomChange: ((Double) -> Void)?

  var onTextSelectionChange: ((Variant_NullType_TextSelection?) -> Void)?

  var canvasView: InkCanvasView { overlayProvider.canvasView }

  func configureCanvasView(_ canvas: InkCanvasView) {
    canvas.owner = self
    canvas.delegate = canvasViewDelegate
    configureCanvasInteraction(canvas)
    updateCanvasPen(canvas)
  }

  override init() {
    super.init()
    container.clipsToBounds = true
    documentView.backgroundColor = .white
    documentView.isOpaque = true
    documentView.displayMode = .singlePage
    documentView.displayDirection = .horizontal
    documentView.usePageViewController(true, withViewOptions: nil)
    interaction.viewport.applyPagerDirectionNow()
    documentView.displayBox = .cropBox
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
      self?.interaction.textActivityChanged()
    }
    textInteractionOverlay.onTextSelectionChange = { [weak self] selection in
      guard let self else { return }
      self.onTextSelectionChange?(selection.map(Variant_NullType_TextSelection.second) ??
        .first(NullType.null))
    }

    canvasView.delegate = canvasViewDelegate
    installPen(currentPen)
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIScene.willDeactivateNotification,
      object: nil,
      queue: .main) { [weak self] notification in
        guard let self, let scene = notification.object as? UIWindowScene,
              scene === self.container.window?.windowScene else { return }
        self.cancelActiveStroke()
      }
    interaction.setBaseMode(ink: false)
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
    if let coreObserver { attachedCore?.removeObserver(coreObserver) }
    attachedCore?.releaseViewer(attachmentID)
    if ownedOptions != nil, let attachedDocument { _ = try? attachedDocument.close() }
    disposed = true
    interaction.dispose()
    pageNavigationRequestID &+= 1
    textInteractionOverlay.discardForDisposal()
    documentView.document = nil
    overlayProvider.dispose()
    viewerDocument = nil
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
      self.releaseAttachment()
      self.disposed = true
      self.interaction.dispose()
      self.cancelViewerCommands()
      self.textInteractionOverlay.discardForDisposal()
      self.cancelActiveStroke(clearLive: false)

      self.pageNavigationRequestID &+= 1
      self.documentView.document = nil
      self.overlayProvider.dispose()
      self.viewerDocument = nil
      self.interaction.setBaseMode(ink: false, enabled: false, finish: false)
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
      self.onZoomChange = nil
    }
  }

  /// Nitro calls this when the native view is removed from the Fabric tree.
  /// Do not wait for HybridObject disposal: the UIKit view and worker queues
  /// can otherwise retain the document and callbacks after unmount.
  func onDropView() {
    dispose()
  }

  // Stroke recording is Android-only; retain the shared Nitro interface.
  func startDebugRecording() {}
  func stopDebugRecording() {}
  func exportDebugRecording() throws -> Promise<String> {
    Promise.rejected(withError: InkSignPdfExportError.notReady)
  }

  enum OperationError: LocalizedError {
    case cancelled

    var errorDescription: String? {
      "operation_cancelled: Viewer operation was cancelled"
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


}
