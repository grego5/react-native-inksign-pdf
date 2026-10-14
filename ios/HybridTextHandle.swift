import Foundation
import NitroModules

/// Stable target identity retains its document core; draft presentation is optional.
final class HybridTextHandle: HybridTextHandleSpec, InkSignPdfTextPageContext {
  private weak var owner: InkSignView?
  private let core: InkSignDocumentCore
  let generation: UInt64
  let pageID: UUID
  private let textID: Double
  var modeSession: InkSignPdfModeSessionToken? { nil }
  private var context: InkSignPdfCorePageContext {
    InkSignPdfCorePageContext(generation: generation, pageID: pageID)
  }

  init(owner: InkSignView, generation: UInt64, pageID: UUID, textID: Double) {
    self.owner = owner
    self.core = owner.documentCore
    self.generation = generation
    self.pageID = pageID
    self.textID = textID
    super.init()
  }

  func getValue() throws -> String { try withCore { try core.textValue(context, id: textID) } }
  func setValue(text: String, options: TextAnnotationOptions?) throws {
    try withCore { try core.setTextValue(context, id: textID, text: text, options: options) }
  }
  func setOptions(options: TextAnnotationOptions) throws {
    try withCore { try core.setTextOptions(context, id: textID, options: options) }
  }
  func adjustSize(delta: Double) throws -> Double {
    try withCore { try core.adjustTextSize(context, id: textID, delta: delta) }
  }

  private func withCore<Value>(_ action: () throws -> Value) throws -> Value {
    try core.onOwnerSync {
      _ = try core.page(context)
      return try action()
    }
  }
}
