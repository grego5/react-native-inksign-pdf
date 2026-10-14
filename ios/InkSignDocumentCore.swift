import Foundation
import NitroModules
import UIKit

/// Document resources and admission are independent of presentation lifetime.
/// Published state and command admission run on the main queue; PDF work uses
/// the coordinator's serial worker. A native operation owns its slot to settlement.
final class InkSignDocumentCore {
  enum ExportOwnership { case document, caller }
  enum Error: Swift.Error, LocalizedError {
    case closed
    var errorDescription: String? { "operation_cancelled: Document core is closed" }
  }

  let coordinator: InkSignPdfDocumentCoordinator
  let recordHistory: Bool
  let fonts = InkSignPdfNamedFontRegistry()
  var appDirectionRTL = UIView.userInterfaceLayoutDirection(for: .unspecified) == .rightToLeft
  let defaultTextFontSize: Double = 16
  let defaultTextColor = "#000000"
  private(set) var activeTextEdit: InkSignPdfDocumentTextEdit?
  private var structuralBusy = false
  func requireContentMutationReady() throws {
    if structuralBusy { throw MutablePageError.operationInProgress }
  }

  func beginTextEdit(_ context: InkSignPdfCorePageContext, id: UInt64) throws -> InkSignPdfDocumentTextEdit {
    try requireContentMutationReady()
    let page = try self.page(context)
    endTextEdit()
    let edit = InkSignPdfDocumentTextEdit(context: context, page: page, id: id)
    activeTextEdit = edit
    return edit
  }

  func updateTextEdit(_ edit: InkSignPdfDocumentTextEdit, annotation: InkSignPdfTextAnnotation?,
                     options: TextAnnotationOptions? = nil) throws {
    try requireContentMutationReady()
    _ = try page(edit.context)
    guard activeTextEdit === edit, edit.active else { throw TextError.cancelled }
    if let options { try setTextOptions(edit.context, id: Double(edit.id), options: options,
      applyToCommitted: false, endEditing: false) }
    guard edit.current != annotation else { return }
    edit.update(annotation)
    changed(.page(edit.page.id))
  }

  func endTextEdit(id: UInt64? = nil) {
    precondition(Thread.isMainThread)
    guard let edit = activeTextEdit, id == nil || id == edit.id else { return }
    activeTextEdit = nil
    edit.end()
    if let current = edit.current { coordinator.updateTextPlacement(current, page: edit.page) }
    changed(.editEnded(edit))
    changed(.page(edit.page.id))
  }
  private var disposed = false
  private var closing = false
  private var closePromise: Promise<Void>?
  private var pending: [Command] = []
  private var running: Command?
  private var observers: [UUID: (Change) -> Void] = [:]

  enum Change {
    case document
    case structure
    case structuralWriteStarted
    case willClose
    case page(UUID)
    case editEnded(InkSignPdfDocumentTextEdit)
    case inkCleared(UUID)
  }

  func observe(_ callback: @escaping (Change) -> Void) -> UUID {
    precondition(Thread.isMainThread)
    let id = UUID()
    observers[id] = callback
    return id
  }

  func removeObserver(_ id: UUID) {
    onOwner { self.observers.removeValue(forKey: id) }
  }

  func changed(_ change: Change) {
    precondition(Thread.isMainThread)
    switch change {
    case .structuralWriteStarted: structuralBusy = true
    case .structure, .document: structuralBusy = false
    default: break
    }
    // Snapshot before callbacks so observers may subscribe/unsubscribe or reenter.
    let callbacks = Array(observers.values)
    callbacks.forEach { $0(change) }
  }

  private var attachedViewerID: UUID?

  func claimViewer(_ id: UUID) throws {
    try requireClientAccess()
    guard attachedViewerID == nil || attachedViewerID == id else {
      throw NSError(domain: "document_already_attached", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "document_already_attached: Detach the existing viewer first"])
    }
    attachedViewerID = id
  }

  func releaseViewer(_ id: UUID) {
    onOwner { if self.attachedViewerID == id { self.attachedViewerID = nil } }
  }

  private struct Command {
    let id: UUID
    let start: () -> Void
    let cancel: () -> Void
  }

  init(artifactPolicy: InkSignPdfCacheArtifactPolicy,
       recordHistory: Bool = false, exportOwnership: ExportOwnership = .caller) {
    self.recordHistory = recordHistory
    coordinator = InkSignPdfDocumentCoordinator(artifactPolicy: artifactPolicy,
      retainsSuccessfulOutputs: exportOwnership == .document)
  }

  deinit {
    // Page and text handles retain the core independently of the document wrapper.
    let coordinator = coordinator
    let fonts = fonts
    let cleanup = { coordinator.dispose(); fonts.clear() }
    if Thread.isMainThread { cleanup() }
    else { DispatchQueue.main.async(execute: cleanup) }
  }

  func submit<Value>(onDiscard: @escaping () -> Void = {},
                     _ action: @escaping () throws -> Promise<Value>) -> Promise<Value> {
    let settlement = InkSignPdfOperationPromise<Value>()
    onOwner {
      guard !self.disposed, !self.closing else { onDiscard(); settlement.reject(Error.closed); return }
      let id = UUID()
      var started = false
      let command = Command(id: id, start: {
        started = true
        do {
          let operation = try action()
          operation.then { value in
            self.onOwner {
              if self.disposed { settlement.reject(Error.closed) }
              else { settlement.resolve(value) }
              self.finish(id)
            }
          }.catch { error in
            self.onOwner { settlement.reject(error); self.finish(id) }
          }
        } catch {
          settlement.reject(error)
          self.finish(id)
        }
      }, cancel: {
        if !started { onDiscard() }
        settlement.reject(Error.closed)
      })
      self.pending.append(command)
      self.drain()
    }
    return settlement.promise
  }

  func dispose() {
    onOwner {
      guard !self.disposed else { return }
      self.disposed = true
      let retired = self.pending
      self.pending.removeAll()
      retired.forEach { $0.cancel() }
      // Keep the running slot until native work settles; cancellation must not
      // release resources underneath an admitted worker.
      self.running?.cancel()
      self.coordinator.dispose()
      self.fonts.clear()
      self.observers.removeAll()
    }
  }

  /// Headless close stops new admission immediately and drains admitted work.
  /// The returned promise settles after the serial worker's cleanup barrier.
  func close() -> Promise<Void> {
    precondition(Thread.isMainThread, "Core close must run on its owner executor")
    if let closePromise { return closePromise }
    endTextEdit()
    let settlement = InkSignPdfOperationPromise<Void>()
    closePromise = settlement.promise
    changed(.willClose)
    let result: Promise<Void> = submit {
      self.closing = true
      let cleanup = InkSignPdfOperationPromise<Void>()
      self.coordinator.dispose()
      self.fonts.clear()
      self.changed(.document)
      self.observers.removeAll()
      self.coordinator.pdfQueue.async {
        DispatchQueue.main.async { cleanup.resolve(()) }
      }
      return cleanup.promise
    }
    closing = true
    result.then { _ in settlement.resolve(()) }
      .catch { error in settlement.reject(error) }
    return settlement.promise
  }

  func requireClientAccess() throws {
    precondition(Thread.isMainThread, "Core reads must run on its owner executor")
    guard !disposed, !closing else { throw Error.closed }
  }

  func requireAdmittedAccess() throws {
    precondition(Thread.isMainThread)
    guard !disposed else { throw Error.closed }
  }

  private func drain() {
    guard !disposed, running == nil, !pending.isEmpty else { return }
    let command = pending.removeFirst()
    running = command
    command.start()
  }

  private func finish(_ id: UUID) {
    guard running?.id == id else { return }
    running = nil
    drain()
  }

  private func onOwner(_ action: @escaping () -> Void) {
    if Thread.isMainThread { action() }
    else { DispatchQueue.main.async(execute: action) }
  }
}
