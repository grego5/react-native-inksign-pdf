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
  private weak var owner: ViewerCanvas?
  private let token: InkSignPdfModeSessionToken

  init(owner: ViewerCanvas, token: InkSignPdfModeSessionToken) {
    self.owner = owner
    self.token = token
    super.init()
  }

  func getPage(pageIndex: Variant_Double_TaggedPageQuery?) throws -> Promise<any HybridDocumentPageSpec> {
    try withOwner { try $0.getSessionPage(token, pageIndex: pageIndex) }
  }

  func focusInputTarget(page: any HybridDocumentPageSpec, id: Double,
                        options: InputTargetFocusOptions?) throws -> Promise<Void> {
    try withOwner { owner in
      guard let page = page as? HybridDocumentPage, page.core === owner.attachedCore else { throw TextError.cancelled }
      return owner.enqueueViewerCommand(modeSession: self.token) {
        try owner.performInputTargetFocus(page, id: id, options: options)
      }
    }
  }

  func selectPage(index: Double) throws {
    try withOwner { try $0.selectPage(index: index, session: token) }
  }

  func requestUserTap() throws -> Promise<PageCoords> {
    try withOwner { try $0.interaction.requestCoordinates(modeSession: token) }
  }

  func setViewport(options: ViewportOptions?) throws -> Promise<Void> {
    try withOwner { $0.setSessionViewport(token, options: options) }
  }

  private func withOwner<T>(_ action: (ViewerCanvas) throws -> T) throws -> T {
    guard let owner else { throw ViewerCanvas.OperationError.cancelled }
    return try owner.performOnMainSync {
      try owner.interaction.requireSession(token)
      return try action(owner)
    }
  }
}

extension ViewerCanvas {

  func setSessionViewport(_ token: InkSignPdfModeSessionToken,
                          options: ViewportOptions?) -> Promise<Void> {
    enqueueViewerCommand(modeSession: token) {
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
