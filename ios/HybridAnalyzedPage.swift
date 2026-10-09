import Foundation
import NitroModules

/** Retains immutable source analysis while keeping the owning view weak. */
final class HybridAnalyzedPage: HybridAnalyzedPageSpec {
  private weak var owner: InkSignView?
  let generation: UInt64
  let pageID: UUID
  let analysis: InkSignPdfPageAnalysis
  let modeSession: InkSignPdfModeSessionToken?

  /** Nitrogen requires a default factory for returned HybridObjects. Handles
   * created through the public API use the owner-backed initializer below. */
  override init() {
    let pageID = UUID()
    self.owner = nil
    self.generation = 0
    self.modeSession = nil
    self.pageID = pageID
    self.analysis = InkSignPdfPageAnalysis(generation: 0,
      pageID: pageID, pageIndex: 0, sourceText: "", characterBounds: [],
      characterVisualRows: [], rules: [], labelCandidates: [],
      estimatedMemoryBytes: 0)
    super.init()
  }

  init(owner: InkSignView,
       generation: UInt64,
       pageID: UUID,
       analysis: InkSignPdfPageAnalysis,
       modeSession: InkSignPdfModeSessionToken? = nil) {
    self.owner = owner
    self.generation = generation
    self.pageID = pageID
    self.analysis = analysis
    self.modeSession = modeSession
    super.init()
  }

  func resolveText(options: ResolveTextOptions) throws -> Double {
    try withOwner { try $0.resolvePreparedText(self, options: options) }
  }

  func getTextValue(id: Double) throws -> String {
    try withOwner { try $0.preparedTextValue(self, id: id) }
  }

  func setTextValue(id: Double, text: String) throws {
    try withOwner { try $0.setPreparedTextValue(self, id: id, text: text) }
  }

  func setTextOptions(id: Double, options: TextAnnotationOptions) throws {
    try withOwner { try $0.setPreparedTextOptions(self, id: id, options: options) }
  }

  func adjustTextSize(id: Double, delta: Double) throws -> Double {
    try withOwner { try $0.adjustPreparedTextSize(self, id: id, delta: delta) }
  }

  func getTextEntry(id: Double) throws -> TextEntry {
    try withOwner { try $0.preparedTextEntry(self, id: id) }
  }

  func getTextEntries() throws -> [TextEntry] {
    try withOwner { try $0.preparedTextEntries(self) }
  }

  func focusText(id: Double, options: TextFocusOptions?) throws -> Promise<Void> {
    try withOwner { try $0.focusPreparedText(self, id: id, options: options) }
  }

  private func withOwner<T>(_ action: (InkSignView) throws -> T) throws -> T {
    guard let owner else { throw InkSignView.TextError.cancelled }
    return try owner.performOnMainSync {
      if let modeSession { try owner.requireModeSession(modeSession) }
      guard !owner.disposed,
            owner.documentCoordinator.generation == generation,
            owner.documentCoordinator.document?.pages.contains(where: { $0.id == pageID }) == true else {
        throw InkSignView.TextError.cancelled
      }
      return try action(owner)
    }
  }
}
