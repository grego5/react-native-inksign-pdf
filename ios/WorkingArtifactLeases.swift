import Foundation

final class InkSignPdfWorkingLease {
  private let release: () -> Void
  init(release: @escaping () -> Void) { self.release = release }
  deinit { release() }
}

/// Keeps working artifacts alive for readers and accepted baselines; content stays core-owned.
final class InkSignPdfWorkingArtifacts {
  private let policy: InkSignPdfCacheArtifactPolicy
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var readers: [URL: Int] = [:]
  private var retired = Set<URL>()
  init(policy: InkSignPdfCacheArtifactPolicy, queue: DispatchQueue) {
    self.policy = policy
    self.queue = queue
  }
  func retain(_ url: URL) -> InkSignPdfWorkingLease {
    lock.lock()
    precondition(!retired.contains(url), "Cannot acquire a retired working artifact")
    readers[url, default: 0] += 1
    lock.unlock()
    return InkSignPdfWorkingLease { self.release(url) }
  }
  func retire(_ url: URL) {
    lock.lock()
    let delete = readers[url] == nil
    if !delete { retired.insert(url) }
    lock.unlock()
    if delete { queue.async { self.policy.deleteExact(url) } }
  }
  private func release(_ url: URL) {
    lock.lock()
    let count = readers[url]!
    let delete: Bool
    if count == 1 {
      readers.removeValue(forKey: url)
      delete = retired.remove(url) != nil
    } else { readers[url] = count - 1; delete = false }
    lock.unlock()
    if delete { queue.async { self.policy.deleteExact(url) } }
  }
}
