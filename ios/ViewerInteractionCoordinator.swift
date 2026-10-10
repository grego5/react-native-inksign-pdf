import Foundation
import UIKit
import NitroModules

/// The host supplies domain operations; interaction state stays with this owner.
protocol ViewerInteractionHost: ViewerViewportHost {
  var interactionGeneration: UInt64? { get }
  var textActivity: InteractionMode { get }
  func finishTextInteraction()
  func armTextInteraction(_ token: InkSignPdfModeSessionToken) throws
  func retireSessionCommands(_ token: InkSignPdfModeSessionToken)
  func applyInputPolicy(ink: Bool, enabled: Bool)
  func publishInteractionState(force: Bool)
  func enableCoordinateTap(_ enabled: Bool)
  func enqueueCoordinatePicker(_ token: InkSignPdfModeSessionToken?,
    start: @escaping () throws -> Void, failure: @escaping (Error) -> Void)
}

/// Owns mode authorization, exclusive input, and presentation handoff on main.
final class ViewerInteractionCoordinator {
  enum Availability: Equatable { case unavailable, ready, navigation, structural }
  final class CoordinateRequest {
    struct Target {
      let generation: UInt64
      let pageID: UUID
      let geometryRevision: UInt64
    }
    let result = InkSignPdfOperationPromise<PageCoords>()
    let modeSession: InkSignPdfModeSessionToken?
    let transitionID: UInt64
    var target: Target?
    init(modeSession: InkSignPdfModeSessionToken?, transitionID: UInt64) {
      self.modeSession = modeSession
      self.transitionID = transitionID
    }
  }
  final class PresentationRequest {
    let revision: UInt64
    let generation: UInt64
    let pageID: UUID
    let geometryRevision: UInt64
    let viewport: ViewportRequest?
    let structural: Bool
    private var completion: ((Result<PageInfo, Error>) -> Void)?
    init(revision: UInt64, generation: UInt64, page: InkSignPdfPageState, viewport: ViewportRequest?,
         structural: Bool, completion: ((Result<PageInfo, Error>) -> Void)?) {
      self.revision = revision
      self.generation = generation
      self.pageID = page.id
      self.geometryRevision = page.geometryRevision
      self.viewport = viewport
      self.structural = structural
      self.completion = completion
    }
    func finish(_ result: Result<PageInfo, Error>) {
      let completion = self.completion
      self.completion = nil
      completion?(result)
    }
  }

  private weak var hostReference: (any ViewerInteractionHost)?
  private var host: any ViewerInteractionHost {
    guard let hostReference else { preconditionFailure("Interaction host must be alive during a transition") }
    return hostReference
  }
  private(set) lazy var viewport = ViewerViewportController(host: host, interaction: self)
  private(set) var currentSession: InkSignPdfModeSessionToken?
  private(set) var isInk = false
  private(set) var availability: Availability = .unavailable
  private(set) var coordinateRequest: CoordinateRequest?
  private(set) var presentation: PresentationRequest?
  private var presentationRevision: UInt64 = 0
  private var transitionID: UInt64 = 0
  private var transitionDepth = 0
  private var deferredForcedStateChange = false

  init(host: any ViewerInteractionHost) { self.hostReference = host }
  var isPickingCoordinates: Bool { coordinateRequest?.target != nil }
  var isStructurallySuspended: Bool { availability == .structural }
  var inputEnabled: Bool {
    availability == .ready && !host.disposed &&
      viewport.viewportReadiness().allowsCommand(fitToPage: false)
  }
  var acceptsInkInput: Bool { inputEnabled && isInk && !isPickingCoordinates }
  var acceptsTextInput: Bool { inputEnabled && !isInk && !isPickingCoordinates }
  var mode: InteractionMode {
    if isPickingCoordinates { return .pagecoords }
    let text = host.textActivity
    if text == .textadd || text == .textedit { return text }
    return isInk ? .ink : .view
  }

  func sessionIsCurrent(_ token: InkSignPdfModeSessionToken) -> Bool {
    !host.disposed && !token.cancelled && currentSession === token &&
      host.interactionGeneration == token.generation
  }
  func requireSession(_ token: InkSignPdfModeSessionToken) throws {
    precondition(Thread.isMainThread)
    guard sessionIsCurrent(token) else { throw InkSignView.LoadError.cancelled }
  }
  private func retire(_ token: InkSignPdfModeSessionToken?) {
    guard let token else { return }
    token.cancelled = true
    host.retireSessionCommands(token)
  }
  func invalidateSession() {
    precondition(Thread.isMainThread)
    let token = currentSession
    currentSession = nil
    transitionID &+= 1
    viewport.supersede()
    retire(token)
  }
  func retireRequests() {
    precondition(Thread.isMainThread)
    let token = currentSession
    let coordinates = coordinateRequest
    let pagePresentation = presentation
    currentSession = nil
    coordinateRequest = nil
    presentation = nil
    transitionID &+= 1
    presentationRevision &+= 1
    if availability == .navigation { availability = .ready }
    viewport.supersede()
    retire(token)
    coordinates?.result.reject(InkSignView.LoadError.cancelled)
    pagePresentation?.finish(.failure(InkSignView.ViewportError.cancelled))
    synchronizePolicy()
  }

  func beginSession(_ mode: InputMode, options: TextModeOptions?) throws -> InkSignPdfModeSessionToken {
    guard !host.disposed else { throw InkSignView.LoadError.cancelled }
    guard let generation = host.interactionGeneration else {
      guard mode == .view else { throw InkSignView.TextError.documentNotOpen }
      let token = InkSignPdfModeSessionToken(generation: host.documentCoordinator.generation, mode: .view)
      token.cancelled = true
      return token
    }
    try viewport.requireViewportReady(request: .preserve)
    let old = currentSession
    let token = InkSignPdfModeSessionToken(generation: generation, mode: mode, textOptions: options)
    currentSession = token
    transitionID &+= 1
    let requestID = transitionID
    isInk = mode == .ink
    transitionDepth += 1
    defer { transitionDepth -= 1; if transitionDepth == 0 { synchronizePolicy(publish: true) } }
    viewport.supersede()
    retire(old)
    try requireSession(token)
    if !isStructurallySuspended { cancelPresentation() }
    guard transitionID == requestID else { throw InkSignView.LoadError.cancelled }
    finishInteraction()
    try requireSession(token)
    if !isStructurallySuspended { availability = .ready }
    synchronizePolicy()
    if mode == .text { try host.armTextInteraction(token) }
    try requireSession(token)
    return token
  }

  @discardableResult
  func finishInteraction() -> Bool {
    let requestID = transitionID
    viewport.cancelMotion()
    guard transitionID == requestID else { return false }
    cancelCoordinates()
    guard transitionID == requestID else { return false }
    host.cancelViewportInk()
    host.finishTextInteraction()
    return transitionID == requestID
  }

  /// Base policy is independent of the token and temporary editor activity.
  func setBaseMode(ink: Bool, enabled: Bool = true, finish: Bool = true) {
    transitionID &+= 1
    let requestID = transitionID
    isInk = ink && host.interactionGeneration != nil
    if !isStructurallySuspended { availability = enabled ? .ready : .unavailable }
    transitionDepth += 1
    defer { transitionDepth -= 1; if transitionDepth == 0 { synchronizePolicy(publish: true) } }
    if finish { finishInteraction() }
    guard transitionID == requestID else { return }
    synchronizePolicy()
  }
  func suspendStructural() {
    availability = .structural
    finishInteraction()
    synchronizePolicy()
  }
  func resumePresentation(publish: Bool = true) {
    availability = .ready
    synchronizePolicy(publish: publish)
  }
  func resetAvailability() { availability = .unavailable }
  func deferStateChange(force: Bool) -> Bool {
    guard transitionDepth > 0 else { return false }
    deferredForcedStateChange = deferredForcedStateChange || force
    return true
  }
  func synchronizePolicy(publish: Bool = false) {
    host.applyInputPolicy(ink: isInk && !isPickingCoordinates, enabled: inputEnabled)
    host.enableCoordinateTap(isPickingCoordinates && inputEnabled)
    if publish && transitionDepth == 0 {
      let force = deferredForcedStateChange
      deferredForcedStateChange = false
      host.publishInteractionState(force: force)
    }
  }
  func textActivityChanged() { synchronizePolicy(publish: true) }

  func requestCoordinates(modeSession: InkSignPdfModeSessionToken?) throws -> Promise<PageCoords> {
    guard !host.disposed else { throw InkSignView.LoadError.cancelled }
    if let modeSession { try requireSession(modeSession) }
    else { invalidateSession() }
    let requestID = transitionID
    cancelCoordinates()
    guard transitionID == requestID else { throw InkSignView.LoadError.cancelled }
    if let modeSession { try requireSession(modeSession) }
    let request = CoordinateRequest(modeSession: modeSession, transitionID: requestID)
    coordinateRequest = request
    host.enqueueCoordinatePicker(modeSession, start: { [weak self] in
      guard let self, self.coordinateRequest === request else { throw InkSignView.LoadError.cancelled }
      try self.viewport.requireViewportReady(request: .preserve)
      guard let page = self.host.documentCoordinator.document?.activePage else {
        throw InkSignView.TextError.documentNotOpen
      }
      let generation = self.host.documentCoordinator.generation
      let geometryRevision = page.geometryRevision
      self.viewport.supersede()
      guard self.coordinateRequest === request, self.coordinateRequestIsAuthorized(request) else {
        throw InkSignView.LoadError.cancelled
      }
      self.cancelPresentation()
      guard self.coordinateRequest === request, self.coordinateRequestIsAuthorized(request) else {
        throw InkSignView.LoadError.cancelled
      }
      self.host.cancelViewportInk()
      self.host.finishTextInteraction()
      guard self.coordinateRequest === request, self.coordinateRequestIsAuthorized(request),
            self.host.documentCoordinator.generation == generation,
            self.host.documentCoordinator.document?.activePage.id == page.id,
            page.geometryRevision == geometryRevision else {
        throw InkSignView.LoadError.cancelled
      }
      self.isInk = false
      request.target = CoordinateRequest.Target(generation: generation,
        pageID: page.id, geometryRevision: geometryRevision)
      self.synchronizePolicy(publish: true)
    }, failure: { [weak self] error in
      guard let self, self.coordinateRequest === request else { return }
      self.cancelCoordinates(error: error)
    })
    return request.result.promise
  }
  private func coordinateTargetIsCurrent(_ target: CoordinateRequest.Target) -> Bool {
    guard !host.disposed, let page = host.documentCoordinator.document?.activePage else { return false }
    return host.documentCoordinator.generation == target.generation &&
      page.id == target.pageID && page.geometryRevision == target.geometryRevision
  }
  private func coordinateRequestIsAuthorized(_ request: CoordinateRequest) -> Bool {
    transitionID == request.transitionID &&
      (request.modeSession.map(sessionIsCurrent) ?? (currentSession == nil))
  }
  private func restoreCoordinateMode(_ request: CoordinateRequest) {
    guard request.target != nil, coordinateRequestIsAuthorized(request) else { return }
    isInk = false
    if let token = request.modeSession, sessionIsCurrent(token) {
      isInk = token.mode == .ink
      if token.mode == .text {
        do { try host.armTextInteraction(token) }
        catch { request.result.reject(error) }
        guard sessionIsCurrent(token) else { return }
      }
    }
    synchronizePolicy(publish: true)
  }
  func cancelCoordinates(error: Error = InkSignView.LoadError.cancelled, restoringMode: Bool = true) {
    guard let request = coordinateRequest else { return }
    coordinateRequest = nil
    host.enableCoordinateTap(false)
    if restoringMode { restoreCoordinateMode(request) }
    request.result.reject(error)
  }
  func selectCoordinates(_ point: CGPoint, page: InkSignPdfPageState, index: Int) {
    guard let request = coordinateRequest, let target = request.target else { return }
    guard coordinateTargetIsCurrent(target), coordinateRequestIsAuthorized(request) else {
      cancelCoordinates(); return
    }
    let size = page.geometry.displaySize
    guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
          point.x <= size.width, point.y <= size.height else { return }
    coordinateRequest = nil
    host.enableCoordinateTap(false)
    restoreCoordinateMode(request)
    guard coordinateRequestIsAuthorized(request), coordinateTargetIsCurrent(target) else {
      request.result.reject(InkSignView.LoadError.cancelled); return
    }
    request.result.resolve(PageCoords(pageId: page.id.uuidString, pageIndex: Double(index),
      x: Double(point.x), y: Double(point.y)))
  }

  @discardableResult
  func beginPresentation(page: InkSignPdfPageState, viewport: ViewportRequest? = nil,
                         structural: Bool = false,
                         completion: ((Result<PageInfo, Error>) -> Void)?) -> PresentationRequest {
    let old = presentation
    presentationRevision &+= 1
    let request = PresentationRequest(revision: presentationRevision,
      generation: host.documentCoordinator.generation, page: page,
      viewport: viewport, structural: structural, completion: completion)
    presentation = request
    availability = structural ? .structural : .navigation
    synchronizePolicy()
    old?.finish(.failure(InkSignView.ViewportError.cancelled))
    return request
  }
  func presentationIsCurrent(_ request: PresentationRequest) -> Bool {
    presentationRevision == request.revision && !host.disposed &&
      host.documentCoordinator.generation == request.generation &&
      host.documentCoordinator.document?.activePage.id == request.pageID &&
      host.documentCoordinator.document?.activePage.geometryRevision == request.geometryRevision
  }
  func claimPresentation(_ request: PresentationRequest) -> Bool {
    guard presentation === request else { return false }
    presentation = nil
    return true
  }
  func cancelPresentation() {
    let request = presentation
    presentation = nil
    presentationRevision &+= 1
    if availability == .navigation {
      availability = .ready
      synchronizePolicy()
    }
    request?.finish(.failure(InkSignView.ViewportError.cancelled))
  }
  func dispose() {
    guard hostReference != nil else {
      currentSession?.cancelled = true
      currentSession = nil
      coordinateRequest?.result.reject(InkSignView.LoadError.cancelled)
      coordinateRequest = nil
      let request = presentation
      presentation = nil
      request?.finish(.failure(InkSignView.ViewportError.cancelled))
      viewport.dispose()
      return
    }
    availability = .unavailable
    isInk = false
    retireRequests()
    viewport.dispose()
  }
}

extension InkSignView: ViewerInteractionHost {
  var interactionGeneration: UInt64? { documentCoordinator.document == nil ? nil : documentCoordinator.generation }
  var textActivity: InteractionMode { textInteractionOverlay.interactionMode() }
  func finishTextInteraction() { textInteractionOverlay.finishForLifecycle() }
  func armTextInteraction(_ token: InkSignPdfModeSessionToken) throws {
    try textInteractionOverlay.armPlacement(generation: token.generation, options: token.textOptions)
  }
  func retireSessionCommands(_ token: InkSignPdfModeSessionToken) {
    let retired = commandQueue.filter { $0.modeSession === token }
    commandQueue.removeAll { $0.modeSession === token }
    retired.forEach { $0.cancel() }
    if runningCommand?.modeSession === token { runningCommand?.cancel() }
  }
  func applyInputPolicy(ink: Bool, enabled: Bool) {
    configureCanvasInteraction(canvasView)
    pdfViewInteractionOwnership.update(pdfView: documentView, editing: ink,
      interactionsEnabled: enabled, placementRecognizer: textInteractionOverlay.placementTapRecognizer)
  }
  func publishInteractionState(force: Bool) { emitChange(force: force) }
  func enableCoordinateTap(_ enabled: Bool) {
    if enabled && !coordinateTapGestureRecognizer.isEnabled {
      configureCoordinateTapPriority(in: documentView)
    }
    coordinateTapGestureRecognizer.isEnabled = enabled
  }
  func enqueueCoordinatePicker(_ token: InkSignPdfModeSessionToken?,
    start: @escaping () throws -> Void, failure: @escaping (Error) -> Void) {
    enqueueViewerCommand(presentation: true, modeSession: token) {
      try start()
      return Promise<Void>.resolved()
    }.catch { [weak self] error in self?.performOnMain { failure(error) } }
  }
}
