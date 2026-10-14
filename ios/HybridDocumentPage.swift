import Foundation
import NitroModules

/// A page retains document identity, never a viewer or presentation lease.
final class HybridDocumentPage: HybridDocumentPageSpec {
  private let core: InkSignDocumentCore
  private let context: InkSignPdfCorePageContext

  init(core: InkSignDocumentCore, context: InkSignPdfCorePageContext) {
    self.core = core
    self.context = context
    super.init()
  }

  func getState() throws -> PageInfo { try read { try core.pageInfo(context) } }
  func resolveInputUnderline(options: ResolveInputUnderlineOptions) throws -> Double {
    try read { try core.resolveText(context, options: InputTargetResolutionOptions(options)) }
  }
  func createInputArea(options: CreateInputAreaOptions) throws -> Double {
    try read { try core.resolveText(context, options: InputTargetResolutionOptions(options)) }
  }
  func getTextValue(id: Double) throws -> String { try read { try core.textValue(context, id: id) } }
  func setTextValue(id: Double, text: String, options: TextAnnotationOptions?) throws {
    try read { try core.setTextValue(context, id: id, text: text, options: options) }
  }
  func setTextOptions(id: Double, options: TextAnnotationOptions) throws {
    try read { try core.setTextOptions(context, id: id, options: options) }
  }
  func adjustTextSize(id: Double, delta: Double) throws -> Double {
    try read { try core.adjustTextSize(context, id: id, delta: delta) }
  }
  func getInputTarget(id: Double) throws -> InputTarget { try read { try core.inputTarget(context, id: id) } }
  func getInputTargets() throws -> [InputTarget] { try read { try core.inputTargets(context) } }
  private func read<Value>(_ action: () throws -> Value) throws -> Value { try core.onOwnerSync(action) }
}
