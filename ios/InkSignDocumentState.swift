import Foundation

struct InkSignPdfTextTargetOptions {
  var font: InkSignPdfNamedFont?
  var fontName: String?
  var fontSize: Double?
  var color: String?
  var direction: TextDirection?
  var maxLines: Int?
  var alignment: TextAlignment?
  var verticalAnchor: TextVerticalAnchor?

  init(_ value: TextAnnotationOptions?) {
    font = nil
    if case .second(let name)? = value?.font { fontName = name } else { fontName = nil }
    fontSize = value?.fontSize
    color = value?.color
    direction = value?.direction
    maxLines = value?.maxLines.map(Int.init)
    alignment = value?.alignment
    verticalAnchor = value?.verticalAnchor
  }

  var publicOptions: TextAnnotationOptions {
    TextAnnotationOptions(untracked: nil, font: fontName.map { .second($0) } ?? .first(.null), fontSize: fontSize, color: color, direction: direction,
      maxLines: maxLines.map(Double.init), alignment: alignment, verticalAnchor: verticalAnchor)
  }
}

struct InkSignPdfTextTarget {
  let id: UInt64
  let pageID: UUID
  var sourceIdentity: String?
  var fieldName: String?
  var canonicalBounds: CGRect
  var options: InkSignPdfTextTargetOptions
  var embeddedValue: String
  var canonicalWritingRule: InkSignPdfCanonicalWritingRule? = nil
  var canonicalDetectionBounds: CGRect
  var excludedSourceRanges: [NSRange] = []

  var annotationOptions: TextAnnotationOptions { options.publicOptions }
}
import NitroModules

/// Serializes cancellation and worker completion onto the promise's owning
/// thread so a late worker result cannot settle an already-cancelled command.
final class InkSignPdfOperationPromise<Value>: @unchecked Sendable {
  let promise: Promise<Value>
  private let lock = NSLock()
  private var settled = false

  init(promise: Promise<Value> = Promise<Value>()) {
    self.promise = promise
  }

  func resolve(_ value: Value) {
    settle(.success(value))
  }

  func reject(_ error: Error) {
    settle(.failure(error))
  }

  private func settle(_ result: Result<Value, Error>) {
    let complete = { [self] in
      lock.lock()
      guard !settled else { lock.unlock(); return }
      settled = true
      lock.unlock()
      switch result {
      case .success(let value): promise.resolve(withResult: value)
      case .failure(let error): promise.reject(withError: error)
      }
    }
    if Thread.isMainThread {
      complete()
    } else {
      DispatchQueue.main.async(execute: complete)
    }
  }
}

/// Owns the currently published PDF and all document generation state.
final class InkSignPdfDocumentCoordinator {
  enum OperationType: Equatable { case open, finalize, structural }
  enum PageMutation {
    case append([InkSignPdfPageState], activePageID: UUID)
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
    case activePageMissing

    var errorDescription: String? {
      switch self {
      case .lastPageRequired: return "last_page_required: The document must retain one page"
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
  var documentID: String? { document?.id.uuidString }
  private(set) var generation: UInt64 = 0
  private(set) var isDisposed = false
  private(set) var structuralDirty = false
  private var activeOperation: OperationToken?
  private var pendingCancellations: [UUID: () -> Void] = [:]
  private var pendingArtifacts = Set<URL>()
  private var ownedOutputs = Set<URL>()
  private let retainsSuccessfulOutputs: Bool
  let workingArtifacts: InkSignPdfWorkingArtifacts
  private var nextTextID: UInt64 = 0
  private var textTargets: [UInt64: InkSignPdfTextTarget] = [:]

  func allocateTextID() throws -> UInt64 {
    let maximum = UInt64(9_007_199_254_740_991)
    guard nextTextID < maximum else {
      throw NSError(domain: "InkSignPdfText", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "text_id_exhausted: The view has exhausted its numeric text IDs"])
    }
    nextTextID += 1
    return nextTextID
  }

  func reserveTextTarget(pageID: UUID,
                         sourceIdentity: String?,
                         fieldName: String?,
                         canonicalBounds: CGRect,
                         options: TextAnnotationOptions?,
                         embeddedValue: String = "",
                         canonicalWritingRule: InkSignPdfCanonicalWritingRule? = nil,
                         canonicalDetectionBounds: CGRect? = nil,
                         excludedSourceRanges: [NSRange] = []) throws -> InkSignPdfTextTarget {
    guard document?.pages.contains(where: { $0.id == pageID }) == true else {
      throw TextError.cancelled
    }
    let normalized = canonicalBounds.standardized
    if let existing = findTextTarget(pageID: pageID, sourceIdentity: sourceIdentity, canonicalBounds: normalized) { return existing }
    let id = try allocateTextID()
    let target = InkSignPdfTextTarget(id: id, pageID: pageID,
      sourceIdentity: sourceIdentity, fieldName: fieldName, canonicalBounds: normalized,
      options: InkSignPdfTextTargetOptions(options), embeddedValue: embeddedValue,
      canonicalWritingRule: canonicalWritingRule,
      canonicalDetectionBounds: canonicalDetectionBounds ?? normalized, excludedSourceRanges: excludedSourceRanges)
    textTargets[id] = target
    return target
  }

  func adoptTextTarget(id: UInt64, pageID: UUID, sourceIdentity: String?,
                       fieldName: String?, canonicalBounds: CGRect,
                       embeddedValue: String,
                       canonicalWritingRule: InkSignPdfCanonicalWritingRule? = nil,
                       canonicalDetectionBounds: CGRect? = nil,
                       excludedSourceRanges: [NSRange] = []) throws -> InkSignPdfTextTarget {
    guard document?.pages.contains(where: { $0.id == pageID }) == true else {
      throw TextError.cancelled
    }
    guard var target = textTargets[id] else { throw TextError.textNotFound }
    guard target.pageID == pageID else { throw TextError.textNotFound }
    if let conflict = findTextTarget(pageID: pageID, sourceIdentity: sourceIdentity, canonicalBounds: canonicalBounds),
       conflict.id != id { throw TextError.targetAmbiguous }
    if let existing = target.sourceIdentity, let sourceIdentity, existing != sourceIdentity {
      throw TextError.targetAmbiguous
    }
    target.sourceIdentity = sourceIdentity ?? target.sourceIdentity
    target.fieldName = fieldName ?? target.fieldName
    target.canonicalBounds = canonicalBounds.standardized
    if let sourceIdentity {
      target.sourceIdentity = sourceIdentity
      target.canonicalWritingRule = canonicalWritingRule
      target.canonicalDetectionBounds = canonicalDetectionBounds ?? canonicalBounds.standardized
      target.excludedSourceRanges = excludedSourceRanges
    } else if target.sourceIdentity == nil {
      target.canonicalDetectionBounds = canonicalBounds.standardized
    }
    // Re-resolution preserves formatting; setTextOptions changes it explicitly.
    if sourceIdentity != nil || target.sourceIdentity == nil { target.embeddedValue = embeddedValue }
    textTargets[id] = target
    return target
  }

  func textTarget(_ id: UInt64, pageID: UUID) throws -> InkSignPdfTextTarget {
    guard let target = textTargets[id], target.pageID == pageID else {
      throw TextError.textNotFound
    }
    return target
  }

  func textTargets(for pageID: UUID) -> [InkSignPdfTextTarget] {
    textTargets.values.filter { $0.pageID == pageID }
  }

  func findTextTarget(pageID: UUID, sourceIdentity: String?, canonicalBounds: CGRect) -> InkSignPdfTextTarget? {
    textTargets.values.first { target in
      guard target.pageID == pageID else { return false }
      if let sourceIdentity { return target.sourceIdentity == sourceIdentity }
      let bounds = target.canonicalBounds
      return target.sourceIdentity == nil && abs(bounds.minX - canonicalBounds.minX) <= 0.000001 &&
        abs(bounds.minY - canonicalBounds.minY) <= 0.000001 && abs(bounds.maxX - canonicalBounds.maxX) <= 0.000001 &&
        abs(bounds.maxY - canonicalBounds.maxY) <= 0.000001
    }
  }

  func updateTextPlacement(_ annotation: InkSignPdfTextAnnotation, page: InkSignPdfPageState) {
    let bounds = annotation.canonicalPlacementBounds(mediaBox: page.geometry.visibleBox)
    guard var target = textTargets[annotation.id] else { preconditionFailure("Committed text requires a reserved target") }
    precondition(target.pageID == page.id)
    target.canonicalBounds = bounds
    target.options.font = annotation.font
    if target.sourceIdentity == nil { target.canonicalDetectionBounds = bounds }
    target.embeddedValue = page.sourceAnalysis.embeddedText(in: target.canonicalDetectionBounds,
                                                           excluding: target.excludedSourceRanges)
    textTargets[annotation.id] = target
  }

  func synchronizeTextPlacement(on page: InkSignPdfPageState) {
    page.history.content.textAnnotations.forEach { updateTextPlacement($0, page: page) }
  }

  func updateTextTarget(_ id: UInt64, pageID: UUID, mutate: (inout InkSignPdfTextTarget) -> Void) throws {
    guard var target = textTargets[id], target.pageID == pageID else {
      throw TextError.textNotFound
    }
    mutate(&target)
    textTargets[id] = target
  }

  func removeTextTargets(for pageID: UUID) {
    textTargets = textTargets.filter { $0.value.pageID != pageID }
  }

  var isDirty: Bool {
    structuralDirty || document?.pages.contains { $0.history.state.isDirty } == true
  }

  static func pageOrder(current: [InkSignPdfPageState],
                        activePageID: UUID,
                        mutation: PageMutation) throws -> PageOrder {
    guard let activeIndex = current.firstIndex(where: { $0.id == activePageID }) else {
      throw PageMutationError.activePageMissing
    }
    switch mutation {
    case .append(let appended, let selectedPageID):
      guard !appended.isEmpty else {
        return PageOrder(pages: current, activePageID: activePageID,
                         addedPageCount: 0, changed: false)
      }
      return PageOrder(pages: current + appended, activePageID: selectedPageID,
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
      assert(current.indices.contains(destination), "Admitted move destination is outside the document")
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

  init(artifactPolicy: InkSignPdfCacheArtifactPolicy = .shared,
       retainsSuccessfulOutputs: Bool = true) {
    self.artifactPolicy = artifactPolicy
    self.retainsSuccessfulOutputs = retainsSuccessfulOutputs
    workingArtifacts = InkSignPdfWorkingArtifacts(policy: artifactPolicy, queue: pdfQueue)
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
    var replacedDocument: InkSignPdfDocumentState?
    var retiredArtifacts = Set<URL>()
    var cancellationHandlers: [() -> Void] = []
    if type == .open {
      activeOperation = nil
      cancellationHandlers = Array(pendingCancellations.values)
      pendingCancellations.removeAll()
      replacedDocument = document
      document = nil
      textTargets.removeAll(keepingCapacity: false)
      structuralDirty = false
      retiredArtifacts = pendingArtifacts
      pendingArtifacts.removeAll()
    } else if activeOperation != nil {
      lock.unlock()
      return nil
    }
    if type == .open || (type == .structural && document == nil) { generation &+= 1 }
    let token = OperationToken(id: UUID(), generation: generation, type: type)
    activeOperation = token
    lock.unlock()
    cancellationHandlers.forEach { $0() }
    let retiredDocuments = [replacedDocument].compactMap { $0 }
    if !retiredDocuments.isEmpty || !retiredArtifacts.isEmpty {
      pdfQueue.async { [artifactPolicy = self.artifactPolicy] in
        Set(retiredDocuments.map(\.workingURL)).forEach(self.workingArtifacts.retire)
        retiredArtifacts.forEach(artifactPolicy.deleteExact)
      }
    }
    return token
  }

  func isCurrent(_ token: OperationToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !isDisposed && generation == token.generation && activeOperation?.id == token.id
  }

  func finish(_ token: OperationToken) {
    settle(token)
  }

  func settle(_ token: OperationToken) {
    lock.lock()
    guard activeOperation?.id == token.id else { lock.unlock(); return }
    activeOperation = nil
    pendingCancellations.removeValue(forKey: token.id)
    lock.unlock()
  }

  func registerCancellation(for token: OperationToken, handler: @escaping () -> Void) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isDisposed, generation == token.generation, activeOperation?.id == token.id else {
      return false
    }
    pendingCancellations[token.id] = handler
    return true
  }

  func registerPending(generation expectedGeneration: UInt64,
                       handler: @escaping () -> Void) -> UUID? {
    lock.lock()
    defer { lock.unlock() }
    guard !isDisposed, generation == expectedGeneration else { return nil }
    let id = UUID()
    pendingCancellations[id] = handler
    return id
  }

  @discardableResult
  func completePending(_ id: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pendingCancellations.removeValue(forKey: id) != nil
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
      throw InkSignPdfExportError.cancelled
    }
    do {
      let output = try artifactPolicy.allocateSignedOutput()
      guard registerPendingArtifact(output, for: token) else {
        artifactPolicy.deleteExact(output)
        discardArtifact(source)
        throw InkSignPdfExportError.cancelled
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
    if retainsSuccessfulOutputs { ownedOutputs.insert(url) }
    return true
  }

  func publish(_ document: InkSignPdfDocumentState, generation: UInt64) -> Bool {
    guard !isDisposed, self.generation == generation else { return false }
    if let previous = self.document, previous.workingURL != document.workingURL {
      workingArtifacts.retire(previous.workingURL)
    }
    self.document = document
    structuralDirty = false
    return true
  }

  func publish(_ document: InkSignPdfDocumentState, operation: OperationToken) -> Bool {
    guard operation.type == .open, isCurrent(operation) else { return false }
    return publish(document, generation: operation.generation)
  }

  /// Atomically publishes core state; working-file leases protect retired readers.
  func publishStructural(_ candidate: InkSignPdfDocumentState,
                         operation: OperationToken) -> InkSignPdfDocumentState? {
    lock.lock()
    defer { lock.unlock() }
    guard operation.type == .structural, !isDisposed,
          generation == operation.generation, activeOperation?.id == operation.id,
          let previous = document else { return nil }
    document = candidate
    let retainedPageIDs = Set(candidate.pages.map(\.id))
    textTargets = textTargets.filter { retainedPageIDs.contains($0.value.pageID) }
    pendingArtifacts.remove(candidate.workingURL)
    structuralDirty = true
    return previous
  }

  /// Publishes logical orientation without changing the working artifact or history.
  func rotatePage(id: UUID, degrees: Int, operation: OperationToken) -> InkSignPdfDocumentState? {
    lock.lock()
    defer { lock.unlock() }
    guard operation.type == .structural, !isDisposed,
          generation == operation.generation, activeOperation?.id == operation.id,
          let document else { return nil }
    guard let index = document.index(of: id) else { return nil }
    let old = document.pages[index]
    let geometry = PageGeometry(mediaBox: old.geometry.mediaBox,
                                rotation: (old.geometry.rotation + degrees) % 360, visibleBox: old.geometry.visibleBox)
    document.replacePage(at: index, with: InkSignPdfPageState(
      id: old.id, tag: old.tag, geometry: geometry, history: old.history,
      geometryRevision: old.geometryRevision &+ 1, sourceGeometry: old.sourceGeometry,
      sourceAnalysis: old.sourceAnalysis, prepared: old.prepared))
    structuralDirty = true
    return document
  }

  func publishInitialStructural(_ candidate: InkSignPdfDocumentState,
                                operation: OperationToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard operation.type == .structural, !isDisposed,
          generation == operation.generation, activeOperation?.id == operation.id,
          case nil = document else { return false }
    document = candidate
    pendingArtifacts.remove(candidate.workingURL)
    structuralDirty = true
    return true
  }

  func clearDocument() {
    if let workingURL = document?.workingURL {
      workingArtifacts.retire(workingURL)
    }
    document = nil
    textTargets.removeAll(keepingCapacity: false)
    structuralDirty = false
  }

  func closeDocument() {
    // Reuse replacement invalidation: retire artifacts and reject late work,
    // then settle the token without installing another document.
    if let token = admit(.open) { settle(token) }
    clearDocument()
  }

  func setStructuralDirty(_ dirty: Bool) {
    structuralDirty = dirty
  }

  func dispose() {
    lock.lock()
    guard !isDisposed else { lock.unlock(); return }
    isDisposed = true
    textTargets.removeAll(keepingCapacity: false)
    generation &+= 1
    activeOperation = nil
    let cancellationHandlers = Array(pendingCancellations.values)
    pendingCancellations.removeAll()
    let artifacts = pendingArtifacts.union(ownedOutputs)
    pendingArtifacts.removeAll()
    ownedOutputs.removeAll()
    clearDocument()
    lock.unlock()
    cancellationHandlers.forEach { $0() }
    pdfQueue.async { [artifactPolicy = self.artifactPolicy] in
      artifacts.forEach(artifactPolicy.deleteExact)
    }
  }
}

/// Published committed state. Page order determines indices; selection belongs to a viewer.
final class InkSignPdfDocumentState {
  let id: UUID
  let sourceURL: URL
  let workingURL: URL
  private(set) var pages: [InkSignPdfPageState]

  init(id: UUID = UUID(), sourceURL: URL, workingURL: URL, pages: [InkSignPdfPageState]) {
    precondition(!pages.isEmpty)
    self.id = id
    self.sourceURL = sourceURL
    self.workingURL = workingURL
    self.pages = pages
  }

  func index(of pageID: UUID) -> Int? { pages.firstIndex { $0.id == pageID } }

  fileprivate func replacePage(at index: Int, with page: InkSignPdfPageState) {
    pages[index] = page
  }
}

final class InkSignPdfPageState {
  let id: UUID
  let tag: String?
  let geometry: PageGeometry
  let history: InkSignPdfPageContentHistory
  let geometryRevision: UInt64
  let sourceGeometry: PageGeometry
  /// Canonical source analysis of the working page, retained across unchanged imports.
  let sourceAnalysis: InkSignPdfPageAnalysis
  let prepared: InkSignPdfPreparedPage

  var contentRevision: UInt64 { history.revision }

  init(id: UUID = UUID(), tag: String? = nil,
       geometry: PageGeometry,
       history: InkSignPdfPageContentHistory = InkSignPdfPageContentHistory(),
       geometryRevision: UInt64 = 0,
       sourceGeometry: PageGeometry? = nil,
       sourceAnalysis: InkSignPdfPageAnalysis,
       prepared: InkSignPdfPreparedPage? = nil) {
    self.id = id
    self.tag = tag
    self.geometry = geometry
    self.history = history
    self.geometryRevision = geometryRevision
    self.sourceGeometry = sourceGeometry ?? geometry
    self.sourceAnalysis = sourceAnalysis
    self.prepared = prepared ?? InkSignPdfPreparedPage(analysis: sourceAnalysis)
  }
}

struct InkSignPdfNativePageInfo {
  let pageIndex: Int
  let pageCount: Int
  let geometry: PageGeometry
}
