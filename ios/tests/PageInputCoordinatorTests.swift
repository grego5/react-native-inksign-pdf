import Foundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ReactNativeInkSignPdf

final class PageInputCoordinatorTests: XCTestCase {
  private let artifacts = InkSignPdfCacheArtifactPolicy.shared

  func testMixedFilesPreserveOrderAndExplicitSourcesNeedNoPresenter() async throws {
    let pdf = try makePDF(label: "first", size: CGSize(width: 80, height: 40))
    let image = try makePNG(color: .systemGreen, size: CGSize(width: 3, height: 2))
    defer { try? FileManager.default.removeItem(at: pdf); try? FileManager.default.removeItem(at: image) }
    let before = stagedURLs()
    let coordinator = InkSignPdfPageInputCoordinator(artifactPolicy: artifacts,
      presenterProvider: { nil }, securityScope: { _, copy in try copy() })

    let staged = try await stage(coordinator, options: .init(type: nil,
      sources: [pdf.absoluteString, image.absoluteString]))
    defer { staged.forEach { artifacts.deleteExact($0.url) } }
    XCTAssertEqual(staged.map(\.type), [.pdf, .image])
    XCTAssertEqual(try Data(contentsOf: staged[0].url).prefix(5), Data("%PDF-".utf8))
    XCTAssertEqual(try Data(contentsOf: staged[1].url), try Data(contentsOf: image))
    XCTAssertEqual(stagedURLs().subtracting(before), Set(staged.map(\.url)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))

    let imageOnly = try await stage(coordinator, options: .init(type: .image,
      sources: [image.absoluteString]))
    imageOnly.forEach { artifacts.deleteExact($0.url) }
    XCTAssertEqual(imageOnly.map(\.type), [.image])
    staged.forEach { artifacts.deleteExact($0.url) }
    XCTAssertEqual(stagedURLs(), before)
  }

  func testTypeMismatchAndUnreadableSelectionDoNotLeavePartialStaging() throws {
    let pdf = try makePDF(label: "valid", size: CGSize(width: 80, height: 40))
    let image = try makePNG(color: .systemBlue, size: CGSize(width: 4, height: 3))
    defer { try? FileManager.default.removeItem(at: pdf); try? FileManager.default.removeItem(at: image) }
    let coordinator = InkSignPdfPageInputCoordinator(artifactPolicy: artifacts,
      presenterProvider: { nil }, securityScope: { _, copy in try copy() })
    let before = stagedURLs()

    assertError(InkSignPdfPageInputCoordinator.PageInputError.unsupportedContent,
      stageResult(coordinator, options: .init(type: .pdf,
        sources: [pdf.absoluteString, image.absoluteString])))
    XCTAssertEqual(stagedURLs(), before)
    assertError(InkSignPdfPageInputCoordinator.PageInputError.unreadableItem,
      stageResult(coordinator, options: .init(type: nil,
        sources: [pdf.absoluteString, temporaryURL("missing-input.pdf").absoluteString])))
    XCTAssertEqual(stagedURLs(), before)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
  }

  func testPickerUsesForegroundNavigationTargetFiltersTypesAndSettlesOnce() throws {
    let pdf = try makePDF(label: "selected", size: CGSize(width: 80, height: 40))
    let image = try makePNG(color: .systemOrange, size: CGSize(width: 4, height: 2))
    defer { try? FileManager.default.removeItem(at: pdf); try? FileManager.default.removeItem(at: image) }

    let first = UIViewController()
    let selected = UIViewController()
    let navigation = UINavigationController(rootViewController: selected)
    let tabs = UITabBarController()
    tabs.viewControllers = [first, navigation]
    tabs.selectedViewController = navigation
    var sourceActions: InkSignPdfPageInputCoordinator.SourceChoiceActions?
    var requestedTypes: [UTType] = []
    var presented: [(UIViewController, UIViewController)] = []
    var documentPicker: UIDocumentPickerViewController?
    let coordinator = InkSignPdfPageInputCoordinator(artifactPolicy: artifacts,
      presenterProvider: { tabs },
      documentPickerFactory: { types in
        requestedTypes = types
        return UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
      },
      controllerPresenter: { presenter, controller in presented.append((presenter, controller)) },
      controllerDismisser: { _, _, completion in completion?() },
      sourceChooser: { _, actions in sourceActions = actions; return UIViewController() },
      securityScope: { _, copy in try copy() })
    let settled = AtomicCounter()
    let result = expectation(description: "mixed file selection stages once")
    coordinator.stage(options: .init(type: nil, sources: nil)) { outcome in
      settled.increment()
      switch outcome {
      case .success(let inputs):
        XCTAssertEqual(inputs.map(\.type), [.pdf, .image])
        XCTAssertEqual(try? Data(contentsOf: inputs[0].url), try? Data(contentsOf: pdf))
        XCTAssertEqual(try? Data(contentsOf: inputs[1].url), try? Data(contentsOf: image))
        inputs.forEach { self.artifacts.deleteExact($0.url) }
      case .failure(let error): XCTFail("Unexpected picker failure: \(error)")
      }
      result.fulfill()
    }
    XCTAssertNotNil(sourceActions)
    XCTAssertEqual(presented.first?.0, selected)
    sourceActions?.chooseFiles()
    XCTAssertEqual(requestedTypes, [.pdf, .image])
    XCTAssertEqual(presented.last?.0, selected)
    documentPicker = presented.last?.1 as? UIDocumentPickerViewController
    XCTAssertTrue(documentPicker?.allowsMultipleSelection == true)
    onMain { coordinator.documentPicker(try! XCTUnwrap(documentPicker), didPickDocumentsAt: [pdf, image]) }
    wait(for: [result], timeout: 10)
    XCTAssertEqual(settled.value, 1)

    var filteredTypes: [UTType] = []
    var filteredPicker: UIDocumentPickerViewController?
    let filtered = InkSignPdfPageInputCoordinator(artifactPolicy: artifacts,
      presenterProvider: { selected }, documentPickerFactory: { types in
        filteredTypes = types
        return UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
      }, controllerPresenter: { _, controller in filteredPicker = controller as? UIDocumentPickerViewController },
      controllerDismisser: { _, _, completion in completion?() },
      securityScope: { _, copy in try copy() })
    let filteredDone = expectation(description: "PDF filter stages one file")
    filtered.stage(options: .init(type: .pdf, sources: nil)) { outcome in
      if case .success(let inputs) = outcome {
        XCTAssertEqual(inputs.map(\.type), [.pdf])
        inputs.forEach { self.artifacts.deleteExact($0.url) }
      } else if case .failure(let error) = outcome { XCTFail("Unexpected failure: \(error)") }
      filteredDone.fulfill()
    }
    XCTAssertEqual(filteredTypes, [.pdf])
    let pdfPicker = try XCTUnwrap(filteredPicker)
    onMain { filtered.documentPicker(pdfPicker, didPickDocumentsAt: [pdf]) }
    wait(for: [filteredDone], timeout: 10)
  }

  func testPhotosProviderCopiesOutOfOrderResultsBeforeTemporarySourcesExpire() throws {
    let first = try makePNG(color: .systemRed, size: CGSize(width: 2, height: 3))
    let second = try makePNG(color: .systemBlue, size: CGSize(width: 5, height: 2))
    defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
    var actions: InkSignPdfPageInputCoordinator.SourceChoiceActions?
    var picker: PHPickerViewController?
    let coordinator = InkSignPdfPageInputCoordinator(artifactPolicy: artifacts,
      presenterProvider: { UIViewController() },
      photoPickerFactory: { PHPickerViewController(configuration: $0) },
      controllerPresenter: { _, controller in picker = controller as? PHPickerViewController },
      controllerDismisser: { _, _, completion in completion?() },
      sourceChooser: { _, value in actions = value; return UIViewController() },
      securityScope: { _, copy in try copy() })
    let result = expectation(description: "photo providers finish out of order")
    var staged: [InkSignPdfStagedPageInput] = []
    coordinator.stage(options: .init(type: .image, sources: nil)) { outcome in
      switch outcome {
      case .success(let inputs): staged = inputs
      case .failure(let error): XCTFail("Unexpected provider failure: \(error)")
      }
      result.fulfill()
    }
    actions?.choosePhotos()
    let photoPicker = try XCTUnwrap(picker)
    XCTAssertEqual(photoPicker.configuration.selectionLimit, 0)
    XCTAssertEqual(photoPicker.configuration.selection, .ordered)
    onMain { coordinator.finishPhotoPicking(itemProviders: [provider(for: first, delay: 0.15),
      provider(for: second, delay: 0)], from: photoPicker) }
    wait(for: [result], timeout: 10)

    XCTAssertEqual(staged.count, 2)
    XCTAssertEqual(try Data(contentsOf: staged[0].url), try Data(contentsOf: first))
    XCTAssertEqual(try Data(contentsOf: staged[1].url), try Data(contentsOf: second))
    try FileManager.default.removeItem(at: first)
    try FileManager.default.removeItem(at: second)
    XCTAssertTrue(staged.allSatisfy { CGImageSourceCreateWithURL($0.url as CFURL, nil) != nil })
    staged.forEach { artifacts.deleteExact($0.url) }
  }

  func testMissingPresenterAndCompetingPresentationDoNotStealOwner() throws {
    let missing = InkSignPdfPageInputCoordinator(artifactPolicy: artifacts, presenterProvider: { nil })
    assertError(InkSignPdfPageInputCoordinator.PageInputError.missingPresenter,
      stageResult(missing, options: .init(type: nil, sources: nil)))

    var ownerActions: InkSignPdfPageInputCoordinator.SourceChoiceActions?
    var ownerSettlements = 0
    let ownerResult = expectation(description: "owner selection cancels once")
    let owner = InkSignPdfPageInputCoordinator(artifactPolicy: artifacts,
      presenterProvider: { UIViewController() },
      controllerPresenter: { _, _ in },
      controllerDismisser: { _, _, completion in completion?() },
      sourceChooser: { _, actions in ownerActions = actions; return UIViewController() })
    let competitor = InkSignPdfPageInputCoordinator(artifactPolicy: artifacts,
      presenterProvider: { UIViewController() }, controllerPresenter: { _, _ in })
    owner.stage(options: .init(type: nil, sources: nil)) { _ in ownerSettlements += 1; ownerResult.fulfill() }
    let competing = expectation(description: "competing owner is rejected")
    competitor.stage(options: .init(type: nil, sources: nil)) { outcome in
      self.assertError(InkSignPdfPageInputCoordinator.PageInputError.operationInProgress, outcome)
      competing.fulfill()
    }
    wait(for: [competing], timeout: 5)
    XCTAssertNotNil(ownerActions)
    onMain { owner.cancelPending() }
    wait(for: [ownerResult], timeout: 5)
    ownerActions?.cancel()
    XCTAssertEqual(ownerSettlements, 1)
  }

  private func stage(_ coordinator: InkSignPdfPageInputCoordinator,
                     options: InkSignPdfPageInputOptions) async throws -> [InkSignPdfStagedPageInput] {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[InkSignPdfStagedPageInput], Error>) in
      onMain {
        coordinator.stage(options: options) { result in
          continuation.resume(with: result)
        }
      }
    }
  }

  private func stageResult(_ coordinator: InkSignPdfPageInputCoordinator,
                           options: InkSignPdfPageInputOptions) -> Result<[InkSignPdfStagedPageInput], Error> {
    let completed = expectation(description: "input staging completes")
    var result: Result<[InkSignPdfStagedPageInput], Error>?
    onMain { coordinator.stage(options: options) { result = $0; completed.fulfill() } }
    // This is a hang watchdog; cold simulator/provider startup can exceed ten seconds.
    wait(for: [completed], timeout: 60)
    guard let result else {
      onMain { coordinator.cancelPending() }
      return .failure(NSError(domain: "PageInputCoordinatorTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Input staging exceeded its completion watchdog"]))
    }
    return result
  }

  private func assertError(_ expected: InkSignPdfPageInputCoordinator.PageInputError,
                           _ result: Result<[InkSignPdfStagedPageInput], Error>,
                           file: StaticString = #filePath, line: UInt = #line) {
    guard case .failure(let error) = result else {
      XCTFail("Expected \(expected), received success", file: file, line: line)
      return
    }
    XCTAssertEqual(error as? InkSignPdfPageInputCoordinator.PageInputError, expected, file: file, line: line)
  }

  private func stagedURLs() -> Set<URL> {
    Set((try? FileManager.default.contentsOfDirectory(at: artifacts.root,
      includingPropertiesForKeys: nil))?.filter { $0.lastPathComponent.hasPrefix(".input-") } ?? [])
  }

  private func makePDF(label: String, size: CGSize) throws -> URL {
    let url = temporaryURL("\(label)-\(UUID().uuidString).pdf")
    try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).writePDF(to: url) { renderer in
      renderer.beginPage()
      NSString(string: label).draw(at: CGPoint(x: 4, y: 4), withAttributes: [.font: UIFont.systemFont(ofSize: 8)])
    }
    return url
  }

  private func makePNG(color: UIColor, size: CGSize) throws -> URL {
    let image = UIGraphicsImageRenderer(size: size).image { context in
      color.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    let url = temporaryURL("image-\(UUID().uuidString).png")
    try XCTUnwrap(image.pngData()).write(to: url)
    return url
  }

  private func provider(for url: URL, delay: TimeInterval) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerFileRepresentation(forTypeIdentifier: UTType.image.identifier,
      fileOptions: [], visibility: .all) { completion in
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
          completion(url, false, nil)
        }
        return nil
      }
    return provider
  }

  private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(name)
  }

  private func onMain(_ action: () -> Void) {
    if Thread.isMainThread { action() } else { DispatchQueue.main.sync(execute: action) }
  }

  private final class AtomicCounter {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); stored += 1; lock.unlock() }
  }
}
