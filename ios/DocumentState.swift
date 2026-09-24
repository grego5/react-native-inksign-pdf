import Foundation
import PDFKit

/// Owns the currently published PDF and all document generation state. UIKit
/// presentation remains in `InkSignView` and `InkPdfView`.
final class InkSignPdfDocumentCoordinator {
  enum OperationType: Equatable { case open, finalize, structural }
  enum PageMutation {
    case append([InkSignPdfPageState])
    case removeActive
    case moveActive(to: Int)
  }
  struct PageOrder {
    let pages: [InkSignPdfPageState]
    let activePageID: UUID
    let addedPageCount: Int
    let changed: Bool
  }
  enum PageMutationError: LocalizedError, Equatable {
    case lastPageRequired
    case invalidPageIndex
    case activePageMissing

    var errorDescription: String? {
      switch self {
      case .lastPageRequired: return "last_page_required: The document must retain one page"
      case .invalidPageIndex: return "invalid_page_index: The destination page index is invalid"
      case .activePageMissing: return "active_page_missing: The active page is not in the document"
      }
    }
  }
  struct OperationToken {
    let id: UUID
    let generation: UInt64
    let type: OperationType
  }

  let artifactPolicy: InkSignPdfCacheArtifactPolicy
  let pdfQueue = DispatchQueue(label: "ReactNativeInkSignPdf.ios.pdf",
                               qos: .userInitiated)
  private let lock = NSLock()
  private(set) var document: InkSignPdfDocumentState?
  private(set) var generation: UInt64 = 0
  private(set) var isDisposed = false
  private(set) var structuralDirty = false
  private var activeOperation: OperationToken?
  private var rollbackDocument: InkSignPdfDocumentState?
  private var rollbackStructuralDirty: Bool?
  private var operationPublishedDocument = false
  private var pendingArtifacts = Set<URL>()
  private var ownedOutputs = Set<URL>()

  var isDirty: Bool {
    structuralDirty || document?.pages.contains { !$0.history.content.isEmpty } == true
  }

  func selectPage(id: UUID) -> Int? {
    guard let document, let index = document.index(of: id) else { return nil }
    document.activePageID = id
    return index
  }

  static func pageOrder(current: [InkSignPdfPageState],
                        activePageID: UUID,
                        mutation: PageMutation) throws -> PageOrder {
    guard let activeIndex = current.firstIndex(where: { $0.id == activePageID }) else {
      throw PageMutationError.activePageMissing
    }
    switch mutation {
    case .append(let appended):
      guard !appended.isEmpty else {
        return PageOrder(pages: current, activePageID: activePageID,
                         addedPageCount: 0, changed: false)
      }
      return PageOrder(pages: current + appended, activePageID: appended[0].id,
                       addedPageCount: appended.count, changed: true)
    case .removeActive:
      guard current.count > 1 else { throw PageMutationError.lastPageRequired }
      var pages = current
      pages.remove(at: activeIndex)
      return PageOrder(pages: pages,
                       activePageID: pages[min(activeIndex, pages.count - 1)].id,
                       addedPageCount: 0,
                       changed: true)
    case .moveActive(let destination):
      guard destination >= 0, destination < current.count else {
        throw PageMutationError.invalidPageIndex
      }
      guard destination != activeIndex else {
        return PageOrder(pages: current, activePageID: activePageID,
                         addedPageCount: 0, changed: false)
      }
      var pages = current
      let active = pages.remove(at: activeIndex)
      pages.insert(active, at: destination)
      return PageOrder(pages: pages, activePageID: activePageID,
                       addedPageCount: 0, changed: true)
    }
  }

  @discardableResult
  func selectPage(at index: Int) -> Bool {
    guard let document, document.pages.indices.contains(index) else { return false }
    document.activePageID = document.pages[index].id
    return true
  }

  init(artifactPolicy: InkSignPdfCacheArtifactPolicy = .shared) {
    self.artifactPolicy = artifactPolicy
  }

  func nextGeneration() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    return generation
  }

  func admit(_ type: OperationType) -> OperationToken? {
    lock.lock()
    guard !isDisposed else { lock.unlock(); return nil }
    var cancelledArtifacts: [URL] = []
    if type == .open, activeOperation?.type == .structural {
      activeOperation = nil
      cancelledArtifacts = Array(pendingArtifacts)
      pendingArtifacts.removeAll()
    } else if activeOperation != nil {
      lock.unlock()
      return nil
    }
    if type == .open { generation &+= 1 }
    let token = OperationToken(id: UUID(), generation: generation, type: type)
    activeOperation = token
    operationPublishedDocument = false
    lock.unlock()
    cancelledArtifacts.forEach(artifactPolicy.deleteExact)
    return token
  }

  func isCurrent(_ token: OperationToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !isDisposed && generation == token.generation && activeOperation?.id == token.id
  }

  func finish(_ token: OperationToken) {
    settle(token, succeeded: true)
  }

  func settle(_ token: OperationToken, succeeded: Bool) {
    lock.lock()
    guard activeOperation?.id == token.id else { lock.unlock(); return }
    activeOperation = nil
    let obsolete: InkSignPdfDocumentState?
    if token.type == .open {
      if succeeded {
        obsolete = rollbackDocument
      } else if operationPublishedDocument {
        obsolete = document
        document = rollbackDocument
        if let rollbackStructuralDirty { structuralDirty = rollbackStructuralDirty }
      } else {
        obsolete = nil
      }
      rollbackDocument = nil
      rollbackStructuralDirty = nil
      operationPublishedDocument = false
    } else {
      obsolete = nil
    }
    lock.unlock()
    if let obsolete, document.map({ obsolete !== $0 }) ?? true {
      artifactPolicy.deleteExact(obsolete.workingURL)
    }
  }

  func registerPendingArtifact(_ url: URL, for token: OperationToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isDisposed, generation == token.generation, activeOperation?.id == token.id else {
      return false
    }
    pendingArtifacts.insert(url)
    return true
  }

  func claimArtifact(_ url: URL) {
    lock.lock()
    pendingArtifacts.remove(url)
    lock.unlock()
  }

  func allocateExportArtifacts(for token: OperationToken) throws -> (source: URL, output: URL) {
    let source = try artifactPolicy.allocateExportSnapshot()
    guard registerPendingArtifact(source, for: token) else {
      artifactPolicy.deleteExact(source)
      throw InkSignView.ExportError.cancelled
    }
    do {
      let output = try artifactPolicy.allocateSignedOutput()
      guard registerPendingArtifact(output, for: token) else {
        artifactPolicy.deleteExact(output)
        discardArtifact(source)
        throw InkSignView.ExportError.cancelled
      }
      return (source, output)
    } catch {
      discardArtifact(source)
      throw error
    }
  }

  func discardArtifact(_ url: URL) {
    lock.lock()
    let wasTracked = pendingArtifacts.remove(url) != nil || ownedOutputs.remove(url) != nil
    lock.unlock()
    if wasTracked { artifactPolicy.deleteExact(url) }
  }

  func publishOutput(_ url: URL, token: OperationToken, publish: () throws -> Void) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isDisposed, generation == token.generation, activeOperation?.id == token.id else {
      pendingArtifacts.remove(url)
      artifactPolicy.deleteExact(url)
      return false
    }
    try publish()
    pendingArtifacts.remove(url)
    ownedOutputs.insert(url)
    return true
  }

  func publish(_ document: InkSignPdfDocumentState, generation: UInt64) -> Bool {
    guard !isDisposed, self.generation == generation else { return false }
    if let previous = self.document, previous.workingURL != document.workingURL {
      rollbackDocument = previous
      rollbackStructuralDirty = structuralDirty
    }
    self.document = document
    structuralDirty = false
    return true
  }

  func publish(_ document: InkSignPdfDocumentState, operation: OperationToken) -> Bool {
    guard operation.type == .open, isCurrent(operation) else { return false }
    guard publish(document, generation: operation.generation) else { return false }
    operationPublishedDocument = true
    return true
  }

  /// Replaces every structural document field as one coordinator transition.
  /// The caller installs the returned document's presentation on the main
  /// thread before releasing the old session and working artifact.
  func publishStructural(_ candidate: InkSignPdfDocumentState,
                         operation: OperationToken) -> InkSignPdfDocumentState? {
    lock.lock()
    defer { lock.unlock() }
    guard operation.type == .structural, !isDisposed,
          generation == operation.generation, activeOperation?.id == operation.id,
          let previous = document else { return nil }
    document = candidate
    generation &+= 1
    pendingArtifacts.remove(candidate.workingURL)
    structuralDirty = true
    return previous
  }

  func publishInitialStructural(_ candidate: InkSignPdfDocumentState,
                                operation: OperationToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard operation.type == .structural, !isDisposed,
          generation == operation.generation, activeOperation?.id == operation.id,
          case nil = document else { return false }
    document = candidate
    generation &+= 1
    pendingArtifacts.remove(candidate.workingURL)
    structuralDirty = true
    return true
  }

  func clearDocument() {
    if let workingURL = document?.workingURL { artifactPolicy.deleteExact(workingURL) }
    document = nil
    structuralDirty = false
  }

  func setStructuralDirty(_ dirty: Bool) {
    structuralDirty = dirty
  }

  func dispose() {
    lock.lock()
    guard !isDisposed else { lock.unlock(); return }
    isDisposed = true
    generation &+= 1
    activeOperation = nil
    let artifacts = pendingArtifacts.union(ownedOutputs)
    let previous = rollbackDocument
    rollbackDocument = nil
    rollbackStructuralDirty = nil
    pendingArtifacts.removeAll()
    ownedOutputs.removeAll()
    clearDocument()
    lock.unlock()
    artifacts.forEach(artifactPolicy.deleteExact)
    if let previous {
      artifactPolicy.deleteExact(previous.workingURL)
    }
  }
}

/// One published mutable document. Its ordered pages are the source of page
/// indexes; the active page is retained by stable identity across mutations.
final class InkSignPdfDocumentState {
  let sourceURL: URL
  let workingURL: URL
  let document: PDFDocument
  private(set) var pages: [InkSignPdfPageState]
  fileprivate(set) var activePageID: UUID

  init(sourceURL: URL,
       workingURL: URL,
       document: PDFDocument,
       pages: [InkSignPdfPageState],
       activePageID: UUID? = nil) {
    precondition(!pages.isEmpty)
    self.sourceURL = sourceURL
    self.workingURL = workingURL
    self.document = document
    self.pages = pages
    self.activePageID = activePageID ?? pages[0].id
    precondition(pages.contains { $0.id == self.activePageID })
  }

  var activePageIndex: Int {
    guard let index = index(of: activePageID) else {
      preconditionFailure("active page ID is absent from the ordered pages")
    }
    return index
  }

  var activePage: InkSignPdfPageState {
    pages[activePageIndex]
  }

  func index(of pageID: UUID) -> Int? {
    pages.firstIndex { $0.id == pageID }
  }
}

final class InkSignPdfPageState {
  let id: UUID
  let page: PDFPage
  let geometry: PageGeometry
  let history: InkSignPdfPageContentHistory

  var contentRevision: UInt64 { history.revision }

  init(id: UUID = UUID(),
       page: PDFPage,
       geometry: PageGeometry,
       history: InkSignPdfPageContentHistory = InkSignPdfPageContentHistory()) {
    self.id = id
    self.page = page
    self.geometry = geometry
    self.history = history
  }
}

struct InkSignPdfNativePageInfo {
  let pageIndex: Int
  let pageCount: Int
  let geometry: PageGeometry
}
