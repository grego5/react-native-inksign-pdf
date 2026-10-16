import Foundation
import CoreGraphics
import NitroModules

final class HybridInkSignDocument: HybridInkSignDocumentSpec {
  let core: DocumentCore
  init(core: DocumentCore) { self.core = core; super.init() }

  var pageCount: Double {
    if Thread.isMainThread { return Double(core.coordinator.document?.pages.count ?? 0) }
    return DispatchQueue.main.sync { Double(core.coordinator.document?.pages.count ?? 0) }
  }
  func getState() throws -> DocumentState { try core.onOwnerSync { try core.state() } }
  func getPage(index: PageQuery) throws -> Promise<any HybridDocumentPageSpec> {
    let query: Variant_Double_TaggedPageQuery
    switch index {
    case .first(let value): query = .first(value)
    case .second(let value): query = .second(value)
    }
    return core.submit {
      let found = try self.core.pageIndex(query, admitted: true)
      let page = self.core.coordinator.document!.pages[found]
      let context = InkSignPdfCorePageContext(generation: self.core.coordinator.generation, pageID: page.id)
      let handle: any HybridDocumentPageSpec = HybridDocumentPage(core: self.core, context: context)
      return .resolved(withResult: handle)
    }
  }
  func getPageIdsByTag(tag: String) throws -> [String] { try core.onOwnerSync { try core.pageIDs(tag: tag) } }
  func loadFonts(fonts: [NamedFontSource]) throws -> Promise<Void> { core.loadFonts(fonts) }
  func addPages(options: DocumentAddPagesOptions?) throws -> Promise<DocumentAddPagesResult> {
    let geometry = try options?.imagePageSize.map { try Self.imageGeometry($0) }
    let result = InkSignPdfOperationPromise<DocumentAddPagesResult>()
    core.addPages(sources: options?.sources, imageGeometry: geometry,
      targetDpi: options?.targetDpi, jpegQuality: options?.jpegQuality, tag: options?.tag,
      type: options?.type.map { $0 == .pdf ? .pdf : .image }).then { added in
        result.resolve(DocumentAddPagesResult(addedPageCount: Double(added),
          pageCount: Double(self.core.coordinator.document?.pages.count ?? 0)))
      }.catch { error in result.reject(error) }
    return result.promise
  }
  func removePage(index: Double) throws -> Promise<Void> {
    core.mutatePage(index: try Self.integer(index))
  }
  func movePage(fromIndex: Double, toIndex: Double) throws -> Promise<Void> {
    core.mutatePage(index: try Self.integer(fromIndex), destination: try Self.integer(toIndex))
  }
  func rotatePage(index: Double, degrees: Double) throws -> Promise<Void> {
    core.rotatePage(index: try Self.integer(index), degrees: try Self.integer(degrees))
  }
  func finalize() throws -> Promise<String> { core.finalize() }
  func close() throws -> Promise<Void> { try core.onOwnerSync { core.close() } }

  static func integer(_ value: Double) throws -> Int {
    guard value.isFinite, value >= 0, value.rounded(.towardZero) == value, value < Double(Int.max) else {
      throw MutablePageError.invalidPageIndex
    }
    return Int(value)
  }
  static func imageGeometry(_ size: ImagePageSize?) throws -> PageGeometry {
    let box = CGRect(x: 0, y: 0, width: size?.width ?? 595.28, height: size?.height ?? 841.89)
    let geometry = PageGeometry(mediaBox: box, rotation: 0)
    guard geometry.isValid else { throw MutablePageError.assemblyFailed }
    return geometry
  }
}

final class HybridInkSignDocumentFactory: HybridInkSignDocumentFactorySpec {
  func createDocument(options: DocumentOptions?) throws -> any HybridInkSignDocumentSpec {
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: options?.recordHistory ?? true)
    core.initialize(options: options)
    return HybridInkSignDocument(core: core)
  }
}
