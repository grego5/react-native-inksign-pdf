import Foundation
import NitroModules

protocol InkSignPdfTextPageContext {
  var generation: UInt64 { get }
  var pageID: UUID { get }
  var modeSession: InkSignPdfModeSessionToken? { get }
}

/// A page retains document identity, never a viewer or presentation lease.
final class HybridDocumentPage: HybridDocumentPageSpec {
  let core: InkSignDocumentCore
  let context: InkSignPdfCorePageContext
  private weak var authorizationOwner: InkSignView?
  let modeSession: InkSignPdfModeSessionToken?
  var generation: UInt64 { context.generation }
  var pageID: UUID { context.pageID }

  init(core: InkSignDocumentCore, context: InkSignPdfCorePageContext,
       owner: InkSignView? = nil, modeSession: InkSignPdfModeSessionToken? = nil) {
    self.core = core
    self.context = context
    authorizationOwner = owner
    self.modeSession = modeSession
    super.init()
  }

  func getState() throws -> PageInfo { try withPageAccess { try core.pageInfo(context) } }
  func undo() throws { try withPageAccess { try core.undo(context) } }
  func redo() throws { try withPageAccess { try core.redo(context) } }
  func clear() throws { try withPageAccess { try core.clear(context) } }
  func clearInk() throws { try withPageAccess { try core.clear(context, inkOnly: true) } }
  func resolveInputUnderline(options: ResolveInputUnderlineOptions) throws -> Double {
    try withPageAccess { try core.resolveText(context, options: InputTargetResolutionOptions(options)) }
  }
  func createInputArea(options: CreateInputAreaOptions) throws -> Double {
    try withPageAccess { try core.resolveText(context, options: InputTargetResolutionOptions(options)) }
  }
  func getTextValue(id: Double) throws -> String { try withPageAccess { try core.textValue(context, id: id) } }
  func setTextValue(id: Double, text: String, options: TextAnnotationOptions?) throws {
    try withPageAccess { try core.setTextValue(context, id: id, text: text, options: options) }
  }
  func setTextOptions(id: Double, options: TextAnnotationOptions) throws {
    try withPageAccess { try core.setTextOptions(context, id: id, options: options) }
  }
  func adjustTextSize(id: Double, delta: Double) throws -> Double {
    try withPageAccess { try core.adjustTextSize(context, id: id, delta: delta) }
  }
  func getInputTarget(id: Double) throws -> InputTarget { try withPageAccess { try core.inputTarget(context, id: id) } }
  func getInputTargets() throws -> [InputTarget] { try withPageAccess { try core.inputTargets(context) } }
  private func withPageAccess<Value>(_ action: () throws -> Value) throws -> Value {
    try core.onOwnerSync {
      if let modeSession {
        guard let owner = authorizationOwner, owner.attachedCore === core else { throw TextError.cancelled }
        try owner.interaction.requireSession(modeSession)
      }
      return try action()
    }
  }
}

extension HybridDocumentPage: InkSignPdfTextPageContext {}
