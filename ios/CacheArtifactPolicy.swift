import Foundation

/// Immutable iOS ownership policy for module-created cache artifacts.
/// Startup scanning and runtime cleanup use the same root and classifiers.
final class InkSignPdfCacheArtifactPolicy {
  static let shared: InkSignPdfCacheArtifactPolicy = {
    do {
      return try InkSignPdfCacheArtifactPolicy()
    } catch {
      preconditionFailure("Invalid ReactNativeInkSignPdf cache configuration: \(error)")
    }
  }()

  let root: URL

  private init() throws {
    let caches = Self.canonicalFileURL(
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    let leaf = try Self.configuredLeafName()
    let candidate = caches.appendingPathComponent(leaf, isDirectory: true)
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    guard !Self.isSymbolicLink(candidate) else { throw ConfigurationError.invalidLeaf }
    root = Self.canonicalFileURL(candidate)
    guard root.deletingLastPathComponent().path == caches.path else {
      throw ConfigurationError.invalidLeaf
    }
    scavenge()
  }

  func allocateSignedOutput() throws -> URL {
    try allocate(prefix: "signed-", suffix: ".pdf")
  }

  func allocateExportScratch() throws -> URL {
    try allocate(prefix: ".signed-", suffix: ".pdf")
  }

  func allocateStagedInput() throws -> URL {
    try allocate(prefix: ".input-", suffix: ".tmp")
  }

  func allocateWorkingSource() throws -> URL {
    try allocate(prefix: ".working-", suffix: ".pdf")
  }

  func allocateExportSnapshot() throws -> URL {
    try allocate(prefix: ".snapshot-", suffix: ".pdf", createFile: false)
  }

  func deleteExact(_ url: URL) {
    guard isOwnedDirectFile(url), !isSymbolicLink(url) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  func validatedSignedOutput(_ url: URL, source: URL) throws -> URL {
    let output = canonical(url)
    guard output.path != canonical(source).path, isSignedOutput(output), isOwnedDirectFile(output) else {
      throw CacheError.invalidOutput
    }
    return output
  }

  private func allocate(prefix: String, suffix: String, createFile: Bool = true) throws -> URL {
    for _ in 0..<32 {
      let url = root.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
      guard isOwnedDirectFile(url) else { throw CacheError.unavailable }
      if !createFile || FileManager.default.createFile(atPath: url.path, contents: nil) { return url }
    }
    throw CacheError.unavailable
  }

  private func scavenge() {
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []) else { return }
    entries.forEach { entry in
      guard !isSymbolicLink(entry), isOwnedDirectFile(entry), isKnownArtifact(entry) else { return }
      deleteExact(entry)
    }
  }

  private func isKnownArtifact(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return Self.signedOutputPattern.firstMatch(in: name) != nil ||
      Self.exportScratchPattern.firstMatch(in: name) != nil ||
      Self.stagedInputPattern.firstMatch(in: name) != nil ||
      Self.workingSourcePattern.firstMatch(in: name) != nil ||
      Self.exportSnapshotPattern.firstMatch(in: name) != nil
  }

  private func isSignedOutput(_ url: URL) -> Bool {
    Self.signedOutputPattern.firstMatch(in: url.lastPathComponent) != nil
  }

  private func isOwnedDirectFile(_ url: URL) -> Bool {
    let resolved = canonical(url)
    guard resolved.deletingLastPathComponent().path == root.path, !isSymbolicLink(url) else {
      return false
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return true
    }
    return !isDirectory.boolValue
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    Self.isSymbolicLink(url)
  }

  private func canonical(_ url: URL) -> URL {
    Self.canonicalFileURL(url)
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  /// Resolves directory symlinks while keeping the leaf name. Foundation strips
  /// `/private` from device container paths only when the full path exists, so
  /// a not-yet-created artifact would otherwise resolve outside an existing root.
  static func canonicalFileURL(_ url: URL) -> URL {
    let standardized = url.standardizedFileURL
    let parent = standardized.deletingLastPathComponent()
    guard parent.path != standardized.path else { return standardized }
    return parent.resolvingSymlinksInPath()
      .appendingPathComponent(standardized.lastPathComponent, isDirectory: url.hasDirectoryPath)
  }

  private static func configuredLeafName() throws -> String {
    let leaf = (Bundle.main.object(forInfoDictionaryKey: "ReactNativeInkSignPdfCacheDirectoryName") as? String)
      ?? "inksignpdf"
    guard isValidLeafName(leaf) else { throw ConfigurationError.invalidLeaf }
    return leaf
  }

  private static func isValidLeafName(_ value: String) -> Bool {
    guard !value.isEmpty, value != ".", value != "..", !value.contains("\0") else { return false }
    guard !value.contains("/"), !value.contains("\\") else { return false }
    return !value.hasPrefix("/")
  }

  private static let signedOutputPattern = try! NSRegularExpression(pattern: "^signed-[^/]+\\.pdf$")
  private static let exportScratchPattern = try! NSRegularExpression(pattern: "^\\.signed-[^/]+\\.pdf$")
  private static let stagedInputPattern = try! NSRegularExpression(pattern: "^\\.input-[^/]+\\.tmp$")
  private static let workingSourcePattern = try! NSRegularExpression(pattern: "^\\.working-[^/]+\\.pdf$")
  private static let exportSnapshotPattern = try! NSRegularExpression(pattern: "^\\.snapshot-[^/]+\\.pdf$")

  enum ConfigurationError: LocalizedError {
    case invalidLeaf
    var errorDescription: String? { "cache directory name must be one non-empty directory component" }
  }

  enum CacheError: LocalizedError {
    case unavailable
    case invalidOutput
    var errorDescription: String? {
      switch self {
      case .unavailable: return "cache artifact allocation failed"
      case .invalidOutput: return "export destination is not a native cache output"
      }
    }
  }
}

@_cdecl("ReactNativeInkSignPdfInitializeCacheArtifacts")
public func ReactNativeInkSignPdfInitializeCacheArtifacts() {
  _ = InkSignPdfCacheArtifactPolicy.shared
}

private extension NSRegularExpression {
  func firstMatch(in value: String) -> NSTextCheckingResult? {
    firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
  }
}
