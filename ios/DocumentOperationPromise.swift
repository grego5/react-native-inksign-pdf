import Foundation
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
