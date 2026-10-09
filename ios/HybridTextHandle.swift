import Foundation
import NitroModules

/** Binds one text target without retaining page analysis or the owning view. */
final class HybridTextHandle: HybridTextHandleSpec, InkSignPdfTextPageContext {
  private weak var owner: InkSignView?
  let generation: UInt64
  let pageID: UUID
  private let textID: Double
  var modeSession: InkSignPdfModeSessionToken? { nil }

  init(owner: InkSignView, generation: UInt64, pageID: UUID, textID: Double) {
    self.owner = owner
    self.generation = generation
    self.pageID = pageID
    self.textID = textID
    super.init()
  }

  func getValue() throws -> String {
    try withOwner { try $0.preparedTextValue(self, id: textID) }
  }

  func setValue(text: String) throws {
    try withOwner { try $0.setPreparedTextValue(self, id: textID, text: text) }
  }

  func setOptions(options: TextAnnotationOptions) throws {
    try withOwner { try $0.setPreparedTextOptions(self, id: textID, options: options) }
  }

  func adjustSize(delta: Double) throws -> Double {
    try withOwner { try $0.adjustPreparedTextSize(self, id: textID, delta: delta) }
  }

  private func withOwner<T>(_ action: (InkSignView) throws -> T) throws -> T {
    guard let owner else { throw InkSignView.TextError.cancelled }
    return try owner.performOnMainSync { try action(owner) }
  }
}
