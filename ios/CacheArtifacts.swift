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
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let leaf = try Self.configuredLeafName()
    let candidate = caches.appendingPathComponent(leaf, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard candidate.deletingLastPathComponent() == caches else {
      throw ConfigurationError.invalidLeaf
    }
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    root = candidate
    scavenge()
  }

  func allocateSignedOutput() throws -> URL {
    try allocate(prefix: "signed-", suffix: ".pdf")
  }

  func allocateExportScratch() throws -> URL {
    try allocate(prefix: ".signed-", suffix: ".pdf")
  }

  func allocateVerificationScratch() throws -> URL {
    try allocate(prefix: ".signed-verify-", suffix: ".pdf")
  }

  func deleteExact(_ url: URL) {
    guard isOwnedDirectFile(url), !isSymbolicLink(url) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  func validatedSignedOutput(_ url: URL, source: URL) throws -> URL {
    let output = canonical(url)
    guard output != canonical(source), isSignedOutput(output), isOwnedDirectFile(output) else {
      throw CacheError.invalidOutput
    }
    return output
  }

  private func allocate(prefix: String, suffix: String) throws -> URL {
    for _ in 0..<32 {
      let url = root.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
      guard isOwnedDirectFile(url) else { throw CacheError.unavailable }
      if FileManager.default.createFile(atPath: url.path, contents: nil) { return url }
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
      Self.verificationScratchPattern.firstMatch(in: name) != nil
  }

  private func isSignedOutput(_ url: URL) -> Bool {
    Self.signedOutputPattern.firstMatch(in: url.lastPathComponent) != nil
  }

  private func isOwnedDirectFile(_ url: URL) -> Bool {
    let resolved = canonical(url)
    guard resolved.deletingLastPathComponent() == root else { return false }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return true
    }
    return !isDirectory.boolValue
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
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
  private static let verificationScratchPattern = try! NSRegularExpression(pattern: "^\\.signed-verify-[^/]+\\.pdf$")

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
