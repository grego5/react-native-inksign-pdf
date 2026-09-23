import PhotosUI
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class PageInputCoordinatorTests: XCTestCase {
  func testLocalSourcesPreserveOrderAndResolveTypes() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inksign-input-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let pdf = directory.appendingPathComponent("first.pdf")
    let image = directory.appendingPathComponent("second.png")
    try Data("%PDF-1.7\n".utf8).write(to: pdf)
    try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")).write(to: image)

    let coordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: InkSignPdfCacheArtifactPolicy.shared)
    let completion = expectation(description: "staging completes")
    var result: Result<[InkSignPdfStagedPageInput], Error>?
    DispatchQueue.main.async {
      coordinator.stage(options: InkSignPdfPageInputOptions(sources: [pdf.path, image.path])) {
        result = $0
        completion.fulfill()
      }
    }
    wait(for: [completion], timeout: 5)

    let staged = try XCTUnwrap(result).get()
    XCTAssertEqual(staged.map(\.type), [.pdf, .image])
    XCTAssertEqual(staged.map(\.url.lastPathComponent).count, 2)
    XCTAssertNotEqual(staged[0].url, pdf)
    XCTAssertNotEqual(staged[1].url, image)
    staged.forEach { InkSignPdfCacheArtifactPolicy.shared.deleteExact($0.url) }
  }

  func testUnsupportedLocalSourceRejectsWithStableErrorAndCleansArtifacts() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inksign-input-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let text = directory.appendingPathComponent("unsupported.txt")
    try Data("not a page".utf8).write(to: text)

    let policy = InkSignPdfCacheArtifactPolicy.shared
    let before = Set((try? FileManager.default.contentsOfDirectory(
      at: policy.root,
      includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? [])
    let coordinator = InkSignPdfPageInputCoordinator(hostView: UIView(), artifactPolicy: policy)
    let completion = expectation(description: "staging fails")
    var result: Result<[InkSignPdfStagedPageInput], Error>?
    DispatchQueue.main.async {
      coordinator.stage(options: InkSignPdfPageInputOptions(sources: [text.path])) {
        result = $0
        completion.fulfill()
      }
    }
    wait(for: [completion], timeout: 5)

    guard case .failure(let error) = try XCTUnwrap(result) else {
      return XCTFail("unsupported input should reject")
    }
    XCTAssertEqual((error as? InkSignPdfPageInputCoordinator.PageInputError), .unsupportedContent)
    let after = Set((try? FileManager.default.contentsOfDirectory(
      at: policy.root,
      includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? [])
    XCTAssertEqual(after, before)
  }

  func testPickerWithoutAttachedPresenterRejectsWithStableError() {
    let coordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: InkSignPdfCacheArtifactPolicy.shared,
      presenterProvider: { nil })
    let completion = expectation(description: "missing presenter")
    var result: Result<[InkSignPdfStagedPageInput], Error>?
    DispatchQueue.main.async {
      coordinator.stage(options: InkSignPdfPageInputOptions()) {
        result = $0
        completion.fulfill()
      }
    }
    wait(for: [completion], timeout: 2)

    guard let result, case .failure(let error) = result else {
      return XCTFail("missing presenter should reject")
    }
    XCTAssertEqual((error as? InkSignPdfPageInputCoordinator.PageInputError), .missingPresenter)
  }

  func testPickerRoutesFilesAndPhotoLibraryWithAllowedTypesAndOrderedPhotos() {
    let presenter = UIViewController()
    var fileTypes: [UTType] = []
    var photoConfiguration: PHPickerConfiguration?
    var choosePhotos: (() -> Void)?
    let filePresented = expectation(description: "Files picker presented")
    let photoPresented = expectation(description: "Photo picker presented")

    let filesCoordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: InkSignPdfCacheArtifactPolicy.shared,
      presenterProvider: { presenter },
      documentPickerFactory: { types in
        fileTypes = types
        return UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
      },
      controllerPresenter: { _, _ in filePresented.fulfill() })
    DispatchQueue.main.async {
      filesCoordinator.stage(options: InkSignPdfPageInputOptions(type: .pdf)) { _ in }
    }
    wait(for: [filePresented], timeout: 2)
    XCTAssertEqual(fileTypes.map(\.identifier), [UTType.pdf.identifier])
    runOnMain { filesCoordinator.cancelPending() }

    let photosCoordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: InkSignPdfCacheArtifactPolicy.shared,
      presenterProvider: { presenter },
      photoPickerFactory: { configuration in
        photoConfiguration = configuration
        return PHPickerViewController(configuration: configuration)
      },
      controllerPresenter: { _, _ in photoPresented.fulfill() },
      sourceChooser: { _, actions in
        choosePhotos = actions.choosePhotos
        return UIViewController()
      })
    DispatchQueue.main.async {
      photosCoordinator.stage(options: InkSignPdfPageInputOptions(type: .image)) { _ in }
      choosePhotos?()
    }
    wait(for: [photoPresented], timeout: 2)
    XCTAssertEqual(photoConfiguration?.selection, .ordered)
    XCTAssertEqual(photoConfiguration?.selectionLimit, 0)
    runOnMain { photosCoordinator.cancelPending() }
  }

  func testPhotoCancellationDismissesPickerAndResolvesEmptySelection() {
    let presenter = UIViewController()
    let pickerPresented = expectation(description: "Photo picker presented")
    let cancelled = expectation(description: "picker cancellation resolves")
    var picker: PHPickerViewController?
    var dismissedPicker: UIViewController?
    var choosePhotos: (() -> Void)?
    let coordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: InkSignPdfCacheArtifactPolicy.shared,
      presenterProvider: { presenter },
      photoPickerFactory: { configuration in
        let result = PHPickerViewController(configuration: configuration)
        picker = result
        return result
      },
      controllerPresenter: { _, _ in pickerPresented.fulfill() },
      controllerDismisser: { controller, _ in dismissedPicker = controller },
      sourceChooser: { _, actions in
        choosePhotos = actions.choosePhotos
        return UIViewController()
      })

    DispatchQueue.main.async {
      coordinator.stage(options: InkSignPdfPageInputOptions(type: .image)) { result in
        if case .success(let staged) = result, staged.isEmpty {
          cancelled.fulfill()
        }
      }
      choosePhotos?()
    }
    wait(for: [pickerPresented], timeout: 2)
    XCTAssertNotNil(picker)
    if let picker {
      runOnMain { coordinator.picker(picker, didFinishPicking: []) }
      wait(for: [cancelled], timeout: 2)
      XCTAssertTrue(dismissedPicker === picker)
    }
  }

  func testDisposalCancellationRejectsPendingPickerAndDismissesIt() {
    let presenter = UIViewController()
    var picker: UIDocumentPickerViewController?
    var dismissed = false
    var completion: Result<[InkSignPdfStagedPageInput], Error>?
    let pickerPresented = expectation(description: "Files picker presented")
    let coordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: InkSignPdfCacheArtifactPolicy.shared,
      presenterProvider: { presenter },
      documentPickerFactory: { types in
        let value = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker = value
        return value
      },
      controllerPresenter: { _, _ in pickerPresented.fulfill() },
      controllerDismisser: { _, _ in dismissed = true })

    DispatchQueue.main.async {
      coordinator.stage(options: InkSignPdfPageInputOptions(type: .pdf)) {
        completion = $0
      }
    }
    wait(for: [pickerPresented], timeout: 2)
    runOnMain { coordinator.cancelPending() }

    XCTAssertTrue(dismissed)
    guard let completion, case .failure(let error) = completion else {
      return XCTFail("disposal should reject the pending operation")
    }
    XCTAssertEqual(
      (error as? InkSignPdfPageInputCoordinator.PageInputError),
      .operationCancelled)
    XCTAssertNotNil(picker)
  }

  func testConcurrentRequestIsRejectedAndStalePickerCannotSettleNewRequest() {
    let presenter = UIViewController()
    var pickers: [UIDocumentPickerViewController] = []
    var conflictCompletion: Result<[InkSignPdfStagedPageInput], Error>?
    var newCompletion: Result<[InkSignPdfStagedPageInput], Error>?
    var firstCompletion: Result<[InkSignPdfStagedPageInput], Error>?
    let newPickerCreated = expectation(description: "replacement picker presented")
    let newSettled = expectation(description: "replacement request settles")
    let coordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: InkSignPdfCacheArtifactPolicy.shared,
      presenterProvider: { presenter },
      documentPickerFactory: { types in
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        pickers.append(picker)
        return picker
      },
      controllerPresenter: { _, _ in
        if pickers.count == 2 { newPickerCreated.fulfill() }
      })

    DispatchQueue.main.async {
      coordinator.stage(options: InkSignPdfPageInputOptions(type: .pdf)) {
        firstCompletion = $0
      }
      coordinator.stage(options: InkSignPdfPageInputOptions(type: .pdf)) {
        conflictCompletion = $0
      }
      coordinator.cancelPending()
      coordinator.stage(options: InkSignPdfPageInputOptions(type: .pdf)) {
        newCompletion = $0
        newSettled.fulfill()
      }
    }
    wait(for: [newPickerCreated], timeout: 2)

    guard let conflictCompletion,
          let firstCompletion,
          case .failure(let conflictError) = conflictCompletion,
          case .failure(let firstError) = firstCompletion else {
      return XCTFail("conflicting and cancelled operations should reject")
    }
    XCTAssertEqual(
      (conflictError as? InkSignPdfPageInputCoordinator.PageInputError),
      .operationInProgress)
    XCTAssertEqual(
      (firstError as? InkSignPdfPageInputCoordinator.PageInputError),
      .operationCancelled)
    XCTAssertGreaterThanOrEqual(pickers.count, 2)
    runOnMain { coordinator.documentPickerWasCancelled(pickers[0]) }
    XCTAssertNil(newCompletion)
    runOnMain { coordinator.documentPickerWasCancelled(pickers[1]) }
    wait(for: [newSettled], timeout: 2)
    if case .success(let staged) = newCompletion {
      XCTAssertTrue(staged.isEmpty)
    } else {
      XCTFail("replacement cancellation should resolve with an empty selection")
    }
  }

  func testSecurityScopeIsBalancedForEachLocalSource() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inksign-scope-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try Data("%PDF-1.7\n".utf8).write(to: source)

    var starts = 0
    var stops = 0
    let completed = expectation(description: "scope staging completes")
    let coordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: InkSignPdfCacheArtifactPolicy.shared,
      securityScope: { _, copy in
        starts += 1
        defer { stops += 1 }
        return try copy()
      })
    var staged: [InkSignPdfStagedPageInput] = []
    DispatchQueue.main.async {
      coordinator.stage(options: InkSignPdfPageInputOptions(sources: [source.path])) {
        if case .success(let result) = $0 { staged = result }
        completed.fulfill()
      }
    }
    wait(for: [completed], timeout: 5)
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(stops, 1)
    staged.forEach { InkSignPdfCacheArtifactPolicy.shared.deleteExact($0.url) }
  }

  func testPhotoProviderResultsArePublishedInPickerOrder() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inksign-photo-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstURL = directory.appendingPathComponent("first.png")
    let secondURL = directory.appendingPathComponent("second.png")
    let firstData = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData {
      UIColor.red.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    let secondData = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData {
      UIColor.blue.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    try firstData.write(to: firstURL)
    try secondData.write(to: secondURL)

    let presenter = UIViewController()
    var picker: PHPickerViewController?
    var choosePhotos: (() -> Void)?
    var result: Result<[InkSignPdfStagedPageInput], Error>?
    let pickerPresented = expectation(description: "photo picker presented")
    let completed = expectation(description: "photo providers staged")
    let coordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: InkSignPdfCacheArtifactPolicy.shared,
      presenterProvider: { presenter },
      photoPickerFactory: { configuration in
        let value = PHPickerViewController(configuration: configuration)
        picker = value
        return value
      },
      controllerPresenter: { _, _ in pickerPresented.fulfill() },
      sourceChooser: { _, actions in
        choosePhotos = actions.choosePhotos
        return UIViewController()
      })

    DispatchQueue.main.async {
      coordinator.stage(options: InkSignPdfPageInputOptions(type: .image)) {
        result = $0
        completed.fulfill()
      }
      choosePhotos?()
    }
    wait(for: [pickerPresented], timeout: 2)
    let providers = [imageProvider(for: firstURL), imageProvider(for: secondURL)]
    if let picker {
      runOnMain { coordinator.finishPhotoPicking(itemProviders: providers, from: picker) }
    }
    wait(for: [completed], timeout: 5)

    let staged = try XCTUnwrap(result).get()
    XCTAssertEqual(staged.count, 2)
    let stagedFirstData = try Data(contentsOf: staged[0].url)
    let stagedSecondData = try Data(contentsOf: staged[1].url)
    XCTAssertEqual(stagedFirstData, firstData)
    XCTAssertEqual(stagedSecondData, secondData)
    staged.forEach { InkSignPdfCacheArtifactPolicy.shared.deleteExact($0.url) }
  }

  func testPartialPhotoProviderFailureCleansEarlierStagedFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inksign-photo-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.png")
    let sourceData = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData {
      UIColor.green.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    try sourceData.write(to: sourceURL)

    let policy = InkSignPdfCacheArtifactPolicy.shared
    let before = Set((try? FileManager.default.contentsOfDirectory(
      at: policy.root,
      includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? [])
    let presenter = UIViewController()
    var picker: PHPickerViewController?
    var choosePhotos: (() -> Void)?
    var result: Result<[InkSignPdfStagedPageInput], Error>?
    let pickerPresented = expectation(description: "photo picker presented")
    let completed = expectation(description: "photo provider failure")
    let coordinator = InkSignPdfPageInputCoordinator(
      hostView: UIView(),
      artifactPolicy: policy,
      presenterProvider: { presenter },
      photoPickerFactory: { configuration in
        let value = PHPickerViewController(configuration: configuration)
        picker = value
        return value
      },
      controllerPresenter: { _, _ in pickerPresented.fulfill() },
      sourceChooser: { _, actions in
        choosePhotos = actions.choosePhotos
        return UIViewController()
      })

    DispatchQueue.main.async {
      coordinator.stage(options: InkSignPdfPageInputOptions(type: .image)) {
        result = $0
        completed.fulfill()
      }
      choosePhotos?()
    }
    wait(for: [pickerPresented], timeout: 2)
    let providers = [
      imageProvider(for: sourceURL),
      NSItemProvider()
    ]
    if let picker {
      runOnMain { coordinator.finishPhotoPicking(itemProviders: providers, from: picker) }
    }
    wait(for: [completed], timeout: 5)

    guard case .failure(let error) = try XCTUnwrap(result) else {
      return XCTFail("partial provider failure should reject")
    }
    XCTAssertEqual(
      (error as? InkSignPdfPageInputCoordinator.PageInputError),
      .unreadableItem)
    let after = Set((try? FileManager.default.contentsOfDirectory(
      at: policy.root,
      includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? [])
    XCTAssertEqual(after, before)
  }

  private func imageProvider(for url: URL) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerFileRepresentation(
      forTypeIdentifier: UTType.image.identifier,
      fileOptions: [],
      visibility: .all) { completion in
        completion(url, false, nil)
        return nil
      }
    return provider
  }

  private func runOnMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.sync(execute: work)
    }
  }
}
