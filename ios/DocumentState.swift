import Foundation
import PDFKit

/// Owns the currently published PDF and all document generation state. UIKit
/// presentation remains in `InkSignView` and `InkPdfView`.
final class InkSignPdfDocumentCoordinator {
  enum OperationKind: Equatable { case open, finalize, structural }
  struct OperationToken {
    let id: UUID
    let generation: UInt64
    let kind: OperationKind
  }

  let artifactPolicy: InkSignPdfCacheArtifactPolicy
  private let lock = NSLock()
  private(set) var document: InkSignPdfDocumentState?
  private(set) var generation: UInt64 = 0
  private(set) var isDisposed = false
  private(set) var structuralDirty = false
  private var activeOperation: OperationToken?
  private var rollbackDocument: InkSignPdfDocumentState?
  private var operationPublishedDocument = false
  private var pendingArtifacts = Set<URL>()
  private var ownedOutputs = Set<URL>()

  var isDirty: Bool {
    structuralDirty || document?.pages.contains { !$0.history.content.isEmpty } == true
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

  func admit(_ kind: OperationKind) -> OperationToken? {
    lock.lock()
    defer { lock.unlock() }
    guard !isDisposed, activeOperation == nil else { return nil }
    if kind != .finalize { generation &+= 1 }
    let token = OperationToken(id: UUID(), generation: generation, kind: kind)
    activeOperation = token
    operationPublishedDocument = false
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
    if token.kind == .open {
      if succeeded {
        obsolete = rollbackDocument
      } else if operationPublishedDocument {
        obsolete = document
        document = rollbackDocument
      } else {
        obsolete = nil
      }
      rollbackDocument = nil
      operationPublishedDocument = false
    } else {
      obsolete = nil
    }
    lock.unlock()
    if let obsolete, document.map({ obsolete !== $0 }) ?? true {
      obsolete.pdfiumSession.close()
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
    }
    self.document = document
    return true
  }

  func publish(_ document: InkSignPdfDocumentState, operation: OperationToken) -> Bool {
    guard operation.kind == .open, isCurrent(operation) else { return false }
    guard publish(document, generation: operation.generation) else { return false }
    operationPublishedDocument = true
    return true
  }

  func clearDocument() {
    document?.pdfiumSession.close()
    if let workingURL = document?.workingURL { artifactPolicy.deleteExact(workingURL) }
    document = nil
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
    pendingArtifacts.removeAll()
    ownedOutputs.removeAll()
    clearDocument()
    lock.unlock()
    artifacts.forEach(artifactPolicy.deleteExact)
    if let previous {
      previous.pdfiumSession.close()
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
  let pdfiumSession: InkSignPdfPdfiumSession
  private(set) var pages: [InkSignPdfPageState]
  private(set) var activePageID: UUID

  init(sourceURL: URL,
       workingURL: URL,
       document: PDFDocument,
       pdfiumSession: InkSignPdfPdfiumSession,
       pages: [InkSignPdfPageState]) {
    precondition(!pages.isEmpty)
    self.sourceURL = sourceURL
    self.workingURL = workingURL
    self.document = document
    self.pdfiumSession = pdfiumSession
    self.pages = pages
    self.activePageID = pages[0].id
  }

  var activePageIndex: Int {
    get { index(of: activePageID) ?? 0 }
    set {
      guard pages.indices.contains(newValue) else { return }
      activePageID = pages[newValue].id
    }
  }

  var activePage: InkSignPdfPageState {
    pages[index(of: activePageID) ?? 0]
  }

  func index(of pageID: UUID) -> Int? {
    pages.firstIndex { $0.id == pageID }
  }
}

final class InkSignPdfPageState {
  let id: UUID
  let page: PDFPage
  let geometry: PageGeometry
  let history = InkSignPdfPageContentHistory()

  var contentRevision: UInt64 { history.revision }

  init(id: UUID = UUID(), page: PDFPage, geometry: PageGeometry) {
    self.id = id
    self.page = page
    self.geometry = geometry
  }
}

struct InkSignPdfNativePageInfo {
  let pageIndex: Int
  let pageCount: Int
  let geometry: PageGeometry
}
