import Foundation
import NitroModules

protocol InkSignPdfTextPageContext {
  var generation: UInt64 { get }
  var pageID: UUID { get }
  var modeSession: InkSignPdfModeSessionToken? { get }
}

/** Retains the core and stable page identity while keeping presentation weak. */
final class HybridAnalyzedPage: HybridAnalyzedPageSpec, InkSignPdfTextPageContext {
  private weak var owner: InkSignView?
  private let core: InkSignDocumentCore?
  let generation: UInt64
  let pageID: UUID
  let modeSession: InkSignPdfModeSessionToken?

  /** Nitrogen requires a default factory for returned HybridObjects. Handles
   * created through the public API use the owner-backed initializer below. */
  override init() {
    let pageID = UUID()
    self.owner = nil
    self.core = nil
    self.generation = 0
    self.modeSession = nil
    self.pageID = pageID
    super.init()
  }

  init(owner: InkSignView,
       generation: UInt64,
       pageID: UUID,
       modeSession: InkSignPdfModeSessionToken? = nil) {
    self.owner = owner
    self.core = owner.documentCore
    self.generation = generation
    self.pageID = pageID
    self.modeSession = modeSession
    super.init()
  }

  func getState() throws -> PageInfo {
    try withCore { try $0.pageInfo(context) }
  }

  private var context: InkSignPdfCorePageContext {
    InkSignPdfCorePageContext(generation: generation, pageID: pageID)
  }

  func resolveInputUnderline(options: ResolveInputUnderlineOptions) throws -> Double {
    try resolveInputTarget(options: InputTargetResolutionOptions(options))
  }

  func createInputArea(options: CreateInputAreaOptions) throws -> Double {
    try resolveInputTarget(options: InputTargetResolutionOptions(options))
  }

  func resolveInputTarget(options: InputTargetResolutionOptions) throws -> Double {
    try withCore { try $0.resolveText(context, options: options) }
  }

  func getTextValue(id: Double) throws -> String {
    try withCore { core in
      let (_, target) = try core.target(context, id: id)
      if let draft = owner?.textInteractionOverlay.preparedDraftText(id: target.id, pageID: pageID) { return draft }
      return try core.textValue(context, id: id)
    }
  }

  func setTextValue(id: Double, text: String, options: TextAnnotationOptions?) throws {
    try withCore { core in
      if let owner { try owner.setPreparedTextValue(self, id: id, text: text, options: options) }
      else { try core.setTextValue(context, id: id, text: text, options: options) }
    }
  }

  func setTextOptions(id: Double, options: TextAnnotationOptions) throws {
    try withCore { core in
      if let owner { try owner.setPreparedTextOptions(self, id: id, options: options) }
      else { try core.setTextOptions(context, id: id, options: options) }
    }
  }

  func adjustTextSize(id: Double, delta: Double) throws -> Double {
    try withCore { core in
      if let owner { return try owner.adjustPreparedTextSize(self, id: id, delta: delta) }
      return try core.adjustTextSize(context, id: id, delta: delta)
    }
  }

  func getInputTarget(id: Double) throws -> InputTarget {
    try withCore { core in
      if let owner { return try owner.preparedInputTarget(self, id: id) }
      return try core.inputTarget(context, id: id)
    }
  }

  func getInputTargets() throws -> [InputTarget] {
    try withCore { core in
      if let owner { return try owner.preparedTextEntries(self) }
      return try core.inputTargets(context)
    }
  }

  func focusInputTarget(id: Double, options: InputTargetFocusOptions?) throws -> Promise<Void> {
    try withOwner { try $0.focusPreparedText(self, id: id, options: options) }
  }

  private func withCore<Value>(_ action: (InkSignDocumentCore) throws -> Value) throws -> Value {
    guard let core else { throw TextError.cancelled }
    return try core.onOwnerSync {
      if let modeSession {
        guard let owner else { throw TextError.cancelled }
        try owner.interaction.requireSession(modeSession)
      }
      _ = try core.page(context)
      return try action(core)
    }
  }

  private func withOwner<T>(_ action: (InkSignView) throws -> T) throws -> T {
    guard let owner else { throw TextError.cancelled }
    return try owner.performOnMainSync {
      if let modeSession { try owner.interaction.requireSession(modeSession) }
      guard !owner.disposed,
            owner.documentCoordinator.generation == generation,
            owner.documentCoordinator.document?.pages.contains(where: { $0.id == pageID }) == true else {
        throw TextError.cancelled
      }
      return try action(owner)
    }
  }
}
