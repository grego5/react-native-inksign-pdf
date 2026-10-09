import Foundation
import NitroModules

/** Owned by the view; handles retain cancellation identity without owning document data. */
final class InkSignPdfModeSessionToken {
  let generation: UInt64
  let mode: InputMode
  let textOptions: TextModeOptions?
  var cancelled = false

  init(generation: UInt64, mode: InputMode, textOptions: TextModeOptions? = nil) {
    self.generation = generation
    self.mode = mode
    self.textOptions = textOptions
  }
}

final class HybridModeSession: HybridModeSessionSpec {
  private weak var owner: InkSignView?
  private let token: InkSignPdfModeSessionToken

  init(owner: InkSignView, token: InkSignPdfModeSessionToken) {
    self.owner = owner
    self.token = token
    super.init()
  }

  func getPage(pageIndex: Double?) throws -> Promise<any HybridAnalyzedPageSpec> {
    try withOwner { try $0.getSessionPage(token, pageIndex: pageIndex) }
  }

  func requestPageCoords() throws -> Promise<PageCoords> {
    try withOwner { try $0.requestSessionPageCoords(token) }
  }

  func setViewport(options: ViewportOptions?) throws -> Promise<Void> {
    try withOwner { $0.setSessionViewport(token, options: options) }
  }

  private func withOwner<T>(_ action: (InkSignView) throws -> T) throws -> T {
    guard let owner else { throw InkSignView.LoadError.cancelled }
    return try owner.performOnMainSync {
      try owner.requireModeSession(token)
      return try action(owner)
    }
  }
}

extension InkSignView {
  func modeSessionIsCurrent(_ token: InkSignPdfModeSessionToken) -> Bool {
    !disposed && !token.cancelled && currentModeSession === token &&
      documentCoordinator.document != nil && documentCoordinator.generation == token.generation
  }

  func requireModeSession(_ token: InkSignPdfModeSessionToken) throws {
    precondition(Thread.isMainThread)
    guard modeSessionIsCurrent(token) else { throw LoadError.cancelled }
  }

  func invalidateModeSession() {
    precondition(Thread.isMainThread)
    guard let token = currentModeSession else { return }
    currentModeSession = nil
    token.cancelled = true
    viewportMotion.cancel()
    fieldFocusRequestID &+= 1
    let retired = commandQueue.filter { $0.modeSession === token }
    commandQueue.removeAll { $0.modeSession === token }
    retired.forEach { $0.cancel() }
    // Keep the active queue slot until the underlying operation completes.
    if runningCommand?.modeSession === token { runningCommand?.cancel() }
  }

  func beginModeSession(_ mode: InputMode,
                        options: TextModeOptions? = nil) throws -> any HybridModeSessionSpec {
    try performOnMainSync {
      guard !self.disposed else { throw LoadError.cancelled }
      guard self.documentCoordinator.document != nil else { throw TextError.documentNotOpen }
      try self.requireViewportReady(request: .preserve)
      self.invalidateModeSession()
      let token = InkSignPdfModeSessionToken(generation: self.documentCoordinator.generation,
                                            mode: mode, textOptions: options)
      self.currentModeSession = token
      self.cancelCoordinateRequest()
      try self.requireModeSession(token)
      try self.applySessionMode(token)
      try self.requireModeSession(token)
      return HybridModeSession(owner: self, token: token)
    }
  }

  func applySessionMode(_ token: InkSignPdfModeSessionToken) throws {
    try requireModeSession(token)
    fieldFocusRequestID &+= 1
    if !structuralInteractionSuspended { cancelPendingPageSwitch() }
    finishInteractionForLifecycle()
    try requireModeSession(token)
    cancelActiveStroke()
    setInteractionMode(editing: token.mode == .ink)
    try requireModeSession(token)
    if token.mode == .text {
      try textInteractionOverlay.armPlacement(generation: token.generation, options: token.textOptions)
    }
  }

  func setSessionViewport(_ token: InkSignPdfModeSessionToken,
                          options: ViewportOptions?) -> Promise<Void> {
    enqueueViewerCommand(presentation: true, modeSession: token) {
      let request = Self.parseViewport(options)
      try self.requireViewportReady(request: request)
      self.fieldFocusRequestID &+= 1
      self.cancelPendingPageSwitch()
      self.finishInteractionForLifecycle()
      try self.requireModeSession(token)
      if case .preserve = request { return Promise<Void>.resolved() }
      guard let target = self.viewportTarget(for: request) else { throw ViewportError.notReady }
      let result = InkSignPdfOperationPromise<Void>()
      self.animateViewport(target: target, modeSession: token) { outcome in
        switch outcome {
        case .success: result.resolve(())
        case .failure(let error): result.reject(error)
        }
      }
      return result.promise
    }
  }
}
