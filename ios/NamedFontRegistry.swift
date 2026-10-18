import Foundation
import CoreText
import UIKit
import NitroModules

/// Exact single-face static TrueType resource. No process-global registration.
final class InkSignPdfNamedFont: Equatable {
  let source: URL
  let bytes: Data
  let graphicsFont: CGFont

  init(source: URL, bytes: Data) throws {
    let values = [UInt8](bytes)
    func word(_ offset: Int) throws -> UInt32 {
      guard offset >= 0, offset <= values.count - 4 else { throw FontError.invalid }
      return values[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    guard values.count >= 12, try word(0) == 0x00010000 else { throw FontError.invalid }
    let count = Int(values[4]) * 256 + Int(values[5])
    guard count > 0, count <= (values.count - 12) / 16 else { throw FontError.invalid }
    var tags = Set<UInt32>()
    for index in 0..<count {
      let start = 12 + index * 16
      let tag = try word(start)
      let offset = Int(try word(start + 8)), length = Int(try word(start + 12))
      guard offset <= values.count, length <= values.count - offset,
            tags.insert(tag).inserted else { throw FontError.invalid }
    }
    guard tags.isSuperset(of: [0x676c7966, 0x6c6f6361, 0x68656164, 0x6d617870, 0x636d6170]),
          !tags.contains(0x66766172),
          let provider = CGDataProvider(data: bytes as CFData),
          let graphicsFont = CGFont(provider) else { throw FontError.invalid }
    self.source = source
    self.bytes = bytes
    self.graphicsFont = graphicsFont
  }

  func font(size: CGFloat) -> UIFont {
    CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil) as UIFont
  }

  static func == (left: InkSignPdfNamedFont, right: InkSignPdfNamedFont) -> Bool { left === right }
}

enum FontError: LocalizedError {
  case invalid
  case conflict(String)
  case notLoaded(String)
  var errorDescription: String? {
    switch self {
    case .invalid: return "invalid_font: A readable local static TrueType font is required"
    case .conflict(let name): return "font_name_conflict: '\(name)' identifies another source"
    case .notLoaded(let name): return "font_not_loaded: '\(name)' has not been loaded by this owner"
    }
  }
}

final class InkSignPdfNamedFontRegistry {
  struct Source {
    let name: String
    let uri: String
  }
  private var names: [String: InkSignPdfNamedFont] = [:]
  private var sources: [URL: InkSignPdfNamedFont] = [:]

  struct Request {
    let names: [String: URL]
    let existing: [URL: InkSignPdfNamedFont]
  }

  /// Owner-executor admission; workers receive an immutable request.
  func request(_ fonts: [Source]) throws -> Request {
    var requested: [String: URL] = [:]
    for font in fonts {
      guard !font.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !font.uri.isEmpty else { throw FontError.invalid }
      let url: URL
      if let parsed = URL(string: font.uri), parsed.scheme != nil {
        guard parsed.isFileURL, parsed.host == nil || parsed.host == "" || parsed.host == "localhost" else {
          throw FontError.invalid
        }
        url = parsed.standardizedFileURL.resolvingSymlinksInPath()
      } else {
        guard (font.uri as NSString).isAbsolutePath else { throw FontError.invalid }
        url = URL(fileURLWithPath: font.uri).standardizedFileURL.resolvingSymlinksInPath()
      }
      if let old = names[font.name]?.source ?? requested[font.name], old != url {
        throw FontError.conflict(font.name)
      }
      requested[font.name] = url
    }
    return Request(names: requested, existing: sources)
  }

  static func prepare(_ request: Request) throws -> [URL: InkSignPdfNamedFont] {
    var resources = request.existing
    for source in Set(request.names.values) where resources[source] == nil {
      resources[source] = try InkSignPdfNamedFont(source: source, bytes: Data(contentsOf: source))
    }
    return resources
  }

  func publish(_ request: Request, resources: [URL: InkSignPdfNamedFont]) {
    sources = resources
    for (name, source) in request.names { names[name] = resources[source]! }
  }

  func resolve(_ option: Variant_NullType_String?, previous: InkSignPdfNamedFont? = nil) throws -> InkSignPdfNamedFont? {
    try resolveSelection(option.map(InkSignPdfFontSelection.init), previous: previous)
  }

  func resolveSelection(_ option: InkSignPdfFontSelection?, previous: InkSignPdfNamedFont? = nil) throws -> InkSignPdfNamedFont? {
    switch option {
    case nil: return previous
    case .system?: return nil
    case .named(let name)?:
      guard let resource = names[name] else { throw FontError.notLoaded(name) }
      return resource
    }
  }

  func clear() { names.removeAll(); sources.removeAll() }
}

extension DocumentCore {
  func loadFonts(_ fonts: [NamedFontSource]) -> Promise<Void> {
    loadFontSources(fonts.map { InkSignPdfNamedFontRegistry.Source(name: $0.name, uri: $0.uri) })
  }
  func loadFontSources(_ fonts: [InkSignPdfNamedFontRegistry.Source]) -> Promise<Void> {
    submit {
      let request = try self.fonts.request(fonts)
      let result = InkSignPdfOperationPromise<Void>()
      self.coordinator.pdfQueue.async {
        let prepared = Result { try InkSignPdfNamedFontRegistry.prepare(request) }
        DispatchQueue.main.async {
          do {
            // Closing drains admitted work; disposal alone cancels publication.
            try self.requireAdmittedAccess()
            self.fonts.publish(request, resources: try prepared.get())
            result.resolve(())
          } catch { result.reject(error) }
        }
      }
      return result.promise
    }
  }
}
