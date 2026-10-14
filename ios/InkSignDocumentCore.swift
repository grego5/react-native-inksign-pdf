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
  var defaultDirectionRTL: Bool?
  var defaultTextFontSize: Double = 16
  var defaultTextColor = "#000000"
  private var disposed = false
  private var closing = false
  private var closePromise: Promise<Void>?
  private var pending: [Command] = []
  private var running: Command?
  private var observers: [UUID: (Change) -> Void] = [:]

  enum Change {
    case document
    case structure
    case page(UUID)
  }

  func observe(_ callback: @escaping (Change) -> Void) -> UUID {
    precondition(Thread.isMainThread)
    let id = UUID()
    observers[id] = callback
    return id
  }

  func removeObserver(_ id: UUID) {
    precondition(Thread.isMainThread)
    observers.removeValue(forKey: id)
  }

  func changed(_ change: Change) {
    precondition(Thread.isMainThread)
    // Snapshot before callbacks so observers may subscribe/unsubscribe or reenter.
    let callbacks = Array(observers.values)
    callbacks.forEach { $0(change) }
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
    let settlement = InkSignPdfOperationPromise<Void>()
    closePromise = settlement.promise
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

  /// Viewer close clears a reusable core. Immediate close cancels clients while
  /// retaining the running native slot until its work finishes.
  func closeViewerDocument(cancelPending: Bool) -> Promise<Void> {
    if !cancelPending {
      return submit {
        self.coordinator.closeDocument()
        self.changed(.document)
        return Promise<Void>.resolved()
      }
    }
    let settlement = InkSignPdfOperationPromise<Void>()
    onOwner {
      guard !self.disposed else { settlement.reject(Error.closed); return }
      let retired = self.pending
      self.pending.removeAll()
      retired.forEach { $0.cancel() }
      self.running?.cancel()
      self.coordinator.closeDocument()
      self.changed(.document)
      settlement.resolve(())
    }
    return settlement.promise
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
