import Foundation

extension InkSignDocumentCore {
  func pageInfo(_ context: InkSignPdfCorePageContext) throws -> PageInfo {
    let page = try self.page(context)
    let state = coordinator.document!
    let index = state.index(of: page.id)!
    let history = page.history
    let geometry = page.geometry
    return PageInfo(tag: page.tag, hasInk: !history.content.drawing.strokes.isEmpty,
      hasText: !history.content.textAnnotations.isEmpty, pageIndex: Double(index),
      pageCount: Double(state.pages.count), isDirty: history.state.isDirty,
      pageId: page.id.uuidString, width: Double(geometry.displaySize.width),
      height: Double(geometry.displaySize.height), rotation: Double(geometry.rotation),
      canUndo: history.canUndo, canRedo: history.canRedo)
  }

  func state() throws -> DocumentState {
    try requireClientAccess()
    return DocumentState(documentId: coordinator.documentID.map { .second($0) } ?? .first(.null), pageCount: Double(coordinator.document?.pages.count ?? 0),
                         isDirty: coordinator.isDirty)
  }

  func pageIDs(tag: String) throws -> [String] {
    try requireClientAccess()
    try Self.validateTag(tag)
    return coordinator.document?.pages.filter { $0.tag == tag }.map { $0.id.uuidString } ?? []
  }

  func pageIndex(_ query: Variant_Double_TaggedPageQuery, admitted: Bool = false) throws -> Int {
    if admitted { try requireAdmittedAccess() } else { try requireClientAccess() }
    guard let state = coordinator.document else { throw TextError.documentNotOpen }
    let value: Double
    switch query {
    case .first(let index): value = index
    case .second(let tagged):
      try Self.validateTag(tagged.tag)
      let matches = state.pages.enumerated().filter { $0.element.tag == tagged.tag }
      let occurrence = tagged.index ?? 0
      guard occurrence.isFinite, occurrence >= 0, occurrence.rounded(.towardZero) == occurrence,
            occurrence < Double(matches.count) else { throw TextError.pageNotFound }
      return matches[Int(occurrence)].offset
    }
    guard value.isFinite, value >= 0, value.rounded(.towardZero) == value,
          value < Double(state.pages.count) else { throw TextError.pageNotFound }
    return Int(value)
  }

  func onOwnerSync<Value>(_ action: () throws -> Value) throws -> Value {
    if Thread.isMainThread { return try action() }
    return try DispatchQueue.main.sync(execute: action)
  }

  static func validateTag(_ tag: String?) throws {
    if let tag, tag.isEmpty { throw TextError.invalidPageTag }
  }
}
