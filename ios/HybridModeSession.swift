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
    try withOwner { try $0.interaction.requestCoordinates(modeSession: token) }
  }

  func setViewport(options: ViewportOptions?) throws -> Promise<Void> {
    try withOwner { $0.setSessionViewport(token, options: options) }
  }

  private func withOwner<T>(_ action: (InkSignView) throws -> T) throws -> T {
    guard let owner else { throw InkSignView.LoadError.cancelled }
    return try owner.performOnMainSync {
      try owner.interaction.requireSession(token)
      return try action(owner)
    }
  }
}

extension InkSignView {

  func setSessionViewport(_ token: InkSignPdfModeSessionToken,
                          options: ViewportOptions?) -> Promise<Void> {
    enqueueViewerCommand(presentation: true, modeSession: token) {
      let request = Self.parseViewport(options)
      try self.interaction.viewport.requireViewportReady(request: request)
      self.interaction.viewport.supersede()
      try self.interaction.requireSession(token)
      self.interaction.cancelPresentation()
      try self.interaction.requireSession(token)
      self.interaction.finishInteraction()
      try self.interaction.requireSession(token)
      if case .preserve = request { return Promise<Void>.resolved() }
      guard let target = self.interaction.viewport.viewportTarget(for: request) else { throw ViewportError.notReady }
      let result = InkSignPdfOperationPromise<Void>()
      self.interaction.viewport.animateViewport(target: target, modeSession: token) { outcome in
        switch outcome {
        case .success: result.resolve(())
        case .failure(let error): result.reject(error)
        }
      }
      return result.promise
    }
  }
}
