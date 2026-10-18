import Foundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct InkSignPdfPageInputOptions {
  let type: InkSignPdfPageInputType?
  let sources: [String]?

  init(type: InkSignPdfPageInputType? = nil, sources: [String]? = nil) {
    self.type = type
    self.sources = sources
  }
}

/// Owns the iOS picker boundary and converts caller/provider-owned inputs into
/// module-owned, ordered files that can outlive a picker callback.
final class InkSignPdfPageInputCoordinator: NSObject {
  typealias Completion = (Result<[InkSignPdfStagedPageInput], Error>) -> Void
  typealias PresenterProvider = () -> [UIViewController]
  typealias DocumentPickerFactory = ([UTType]) -> UIDocumentPickerViewController
  typealias PhotoPickerFactory = (PHPickerConfiguration) -> PHPickerViewController
  typealias ControllerPresenter = (UIViewController, UIViewController) -> Void
  typealias ControllerDismisser = (UIViewController, Bool, (() -> Void)?) -> Void
  typealias SecurityScope = (
    _ url: URL,
    _ copy: () throws -> InkSignPdfStagedPageInput
  ) throws -> InkSignPdfStagedPageInput

  struct SourceChoiceActions {
    let chooseFiles: () -> Void
    let choosePhotos: () -> Void
    let cancel: () -> Void
  }

  typealias SourceChooser = (UIViewController, SourceChoiceActions) -> UIViewController?

  private static weak var pickerLease: Request?
  private var selectionClosed = false
  private let artifactPolicy: InkSignPdfCacheArtifactPolicy
  private let presenterProvider: PresenterProvider?
  private let documentPickerFactory: DocumentPickerFactory
  private let photoPickerFactory: PhotoPickerFactory
  private let controllerPresenter: ControllerPresenter
  private let controllerDismisser: ControllerDismisser
  private let sourceChooser: SourceChooser
  private let securityScope: SecurityScope
  private var activeRequest: Request?

  init(
    artifactPolicy: InkSignPdfCacheArtifactPolicy,
    presenterProvider: PresenterProvider? = nil,
    documentPickerFactory: @escaping DocumentPickerFactory = {
      UIDocumentPickerViewController(forOpeningContentTypes: $0, asCopy: false)
    },
    photoPickerFactory: @escaping PhotoPickerFactory = {
      PHPickerViewController(configuration: $0)
    },
    controllerPresenter: @escaping ControllerPresenter = { presenter, controller in
      presenter.present(controller, animated: true)
    },
    controllerDismisser: @escaping ControllerDismisser = { controller, animated, completion in
      controller.dismiss(animated: animated, completion: completion)
    },
    sourceChooser: SourceChooser? = nil,
    securityScope: @escaping SecurityScope = { url, copy in
      let scoped = url.startAccessingSecurityScopedResource()
      defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
      }
      return try copy()
    }
  ) {
    self.artifactPolicy = artifactPolicy
    self.presenterProvider = presenterProvider
    self.documentPickerFactory = documentPickerFactory
    self.photoPickerFactory = photoPickerFactory
    self.controllerPresenter = controllerPresenter
    self.controllerDismisser = controllerDismisser
    self.sourceChooser = sourceChooser ?? Self.makeSourceChooser()
    self.securityScope = securityScope
    super.init()
  }

  deinit {
    guard let request = activeRequest else { return }
    request.cancel()
    let policy = artifactPolicy
    let dismisser = controllerDismisser
    let cleanup = {
      Self.finishSelection(request, using: dismisser) {
        policy.deleteURLs(request.takeStagedURLs())
        request.completion(.failure(PageInputError.operationCancelled))
      }
    }
    if Thread.isMainThread { cleanup() } else { DispatchQueue.main.async(execute: cleanup) }
  }

  func stage(options: InkSignPdfPageInputOptions, completion: @escaping Completion) {
    precondition(Thread.isMainThread, "page input staging must start on the main thread")
    guard activeRequest == nil else {
      completion(.failure(PageInputError.operationInProgress))
      return
    }

    let request = Request(options: options, completion: completion)
    activeRequest = request
    if options.sources == nil && selectionClosed {
      complete(request, with: .failure(PageInputError.operationCancelled))
      return
    }
    if let sources = options.sources {
      stageFiles(resolving: { try sources.map { try Self.localURL(from: $0) } }, for: request)
      return
    }
    request.awaitingSelection = true
    guard Self.pickerLease == nil else {
      complete(request, with: .failure(PageInputError.operationInProgress))
      return
    }
    Self.pickerLease = request
    presentPicker(for: request)
  }

  func cancelSelection() {
    precondition(Thread.isMainThread)
    selectionClosed = true
    if activeRequest?.awaitingSelection == true { cancelPending() }
  }

  private static func finishSelection(_ request: Request, using dismisser: ControllerDismisser,
                                      completion: @escaping () -> Void = {}) {
    request.awaitingSelection = false
    if let observer = request.sceneObserver {
      NotificationCenter.default.removeObserver(observer)
      request.sceneObserver = nil
    }
    dismissController(request, animated: false, using: dismisser) {
      request.presenter = nil
      request.presentationScene = nil
      if Self.pickerLease === request { Self.pickerLease = nil }
      completion()
    }
  }

  private static func dismissController(_ request: Request, animated: Bool,
                                        using dismisser: ControllerDismisser,
                                        completion: @escaping () -> Void) {
    switch request.dismissal {
    case .finished:
      completion()
      return
    case .inProgress(var completions):
      completions.append(completion)
      request.dismissal = .inProgress(completions)
      return
    case .pending:
      request.dismissal = .inProgress([completion])
    }
    let finish = {
      request.controller = nil
      guard case .inProgress(let completions) = request.dismissal else {
        preconditionFailure("Picker dismissal must complete once")
      }
      request.dismissal = .finished
      completions.forEach { $0() }
    }
    if let controller = request.controller { dismisser(controller, animated, finish) }
    else { finish() }
  }

  /// Invalidates the picker and all worker callbacks. The eventual addPages
  /// operation receives a stable cancellation error; user dismissal is handled
  /// separately by the picker delegates and resolves with an empty selection.
  func cancelPending() {
    precondition(Thread.isMainThread, "page input cancellation must run on the main thread")
    guard let request = activeRequest else { return }
    request.cancel()
    complete(request, with: .failure(PageInputError.operationCancelled))
  }

  enum PageInputError: LocalizedError, Equatable {
    case missingPresenter
    case ambiguousPresenter
    case operationInProgress
    case operationCancelled
    case staleCallback
    case invalidSource
    case unreadableItem
    case unsupportedContent

    var errorDescription: String? {
      switch self {
      case .missingPresenter:
        return "missing_presenter: Unable to present the page picker"
      case .ambiguousPresenter:
        return "ambiguous_presenter: Multiple foreground presenters can present the page picker"
      case .operationInProgress:
        return "operation_in_progress: Another page input operation is active"
      case .operationCancelled:
        return "operation_cancelled: Page input staging was cancelled"
      case .staleCallback:
        return "stale_callback: The page picker result is no longer current"
      case .invalidSource:
        return "invalid_source: Page input must be a local path or file URL"
      case .unreadableItem:
        return "unreadable_item: Unable to read the selected page input"
      case .unsupportedContent:
        return "unsupported_content: The selected item is not a supported PDF or image"
      }
    }
  }

  private final class Request {
    enum Dismissal {
      case pending
      case inProgress([() -> Void])
      case finished
    }

    let options: InkSignPdfPageInputOptions
    let completion: Completion
    var controller: UIViewController?
    var awaitingSelection = false
    var sceneObserver: NSObjectProtocol?
    var presenter: UIViewController?
    var presentationScene: UIWindowScene?
    var dismissal: Dismissal = .pending

    private let lock = NSLock()
    private var cancelled = false
    private var stagedURLs: [URL] = []

    init(options: InkSignPdfPageInputOptions, completion: @escaping Completion) {
      self.options = options
      self.completion = completion
    }

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }

    func isCancelled() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func retainStagedURL(_ url: URL, policy: InkSignPdfCacheArtifactPolicy) {
      lock.lock()
      if cancelled {
        lock.unlock()
        policy.deleteExact(url)
        return
      }
      stagedURLs.append(url)
      lock.unlock()
    }

    func takeStagedURLs() -> [URL] {
      lock.lock()
      defer { lock.unlock() }
      let urls = stagedURLs
      stagedURLs.removeAll()
      return urls
    }
  }

  private static func makeSourceChooser() -> SourceChooser {
    { _, actions in
      let alert = UIAlertController(
        title: "Add pages",
        message: "Choose a page source",
        preferredStyle: .actionSheet)
      alert.addAction(UIAlertAction(title: "Files", style: .default) { _ in
        actions.chooseFiles()
      })
      alert.addAction(UIAlertAction(title: "Photo Library", style: .default) { _ in
        actions.choosePhotos()
      })
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
        actions.cancel()
      })
      return alert
    }
  }

  private func presenter() throws -> UIViewController? {
    let roots: [UIViewController]
    if let presenterProvider {
      roots = presenterProvider()
    } else {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
      roots = scenes.flatMap(\.windows).filter { $0.isKeyWindow && !$0.isHidden }
        .compactMap(\.rootViewController)
    }
    guard roots.count <= 1 else { throw PageInputError.ambiguousPresenter }
    return roots.first.map { topPresenter(from: $0) }
  }

  private func topPresenter(from root: UIViewController) -> UIViewController {
    var current = root
    while true {
      if let presented = current.presentedViewController, !presented.isBeingDismissed {
        current = presented
      } else if let navigation = current as? UINavigationController, let visible = navigation.visibleViewController {
        current = visible
      } else if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController {
        current = selected
      } else {
        break
      }
    }
    return current
  }

  private func presentPicker(for request: Request) {
    let presenter: UIViewController
    do {
      guard let resolved = try self.presenter() else { throw PageInputError.missingPresenter }
      presenter = resolved
    } catch {
      complete(request, with: .failure(error))
      return
    }
    request.presenter = presenter
    request.presentationScene = presenter.viewIfLoaded?.window?.windowScene
    if let scene = request.presentationScene {
      request.sceneObserver = NotificationCenter.default.addObserver(
        forName: UIScene.didDisconnectNotification, object: scene, queue: .main) { [weak self] _ in
          guard let self, self.activeRequest === request else { return }
          self.cancelPending()
        }
    }
    switch request.options.type {
    case .pdf:
      presentFiles(for: request, from: presenter)
    case .image, nil:
      presentSourceChoice(for: request, from: presenter)
    }
  }

  private func presentSourceChoice(for request: Request, from presenter: UIViewController) {
    let actions = SourceChoiceActions(
      chooseFiles: { [weak self] in self?.chooseFiles(for: request, from: presenter) },
      choosePhotos: { [weak self] in self?.choosePhotos(for: request, from: presenter) },
      cancel: { [weak self] in self?.complete(request, with: .success([])) })
    let controller = sourceChooser(
      presenter,
      actions)
    guard let controller else {
      complete(request, with: .failure(PageInputError.missingPresenter))
      return
    }
    request.controller = controller
    configurePopover(controller, from: presenter)
    controllerPresenter(presenter, controller)
  }

  private func chooseFiles(for request: Request, from presenter: UIViewController) {
    guard activeRequest === request, !request.isCancelled() else { return }
    Self.dismissController(request, animated: true, using: controllerDismisser) { [weak self] in
      guard let self, self.activeRequest === request, !request.isCancelled() else { return }
      self.presentFiles(for: request, from: self.topPresenter(from: presenter))
    }
  }

  private func choosePhotos(for request: Request, from presenter: UIViewController) {
    guard activeRequest === request, !request.isCancelled() else { return }
    Self.dismissController(request, animated: true, using: controllerDismisser) { [weak self] in
      guard let self, self.activeRequest === request, !request.isCancelled() else { return }
      self.presentPhotos(for: request, from: self.topPresenter(from: presenter))
    }
  }

  private func presentFiles(for request: Request, from presenter: UIViewController) {
    let contentTypes: [UTType]
    switch request.options.type {
    case .pdf:
      contentTypes = [.pdf]
    case .image:
      contentTypes = [.image]
    case nil:
      contentTypes = [.pdf, .image]
    }
    let picker = documentPickerFactory(contentTypes)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    request.dismissal = .pending
    request.controller = picker
    configurePopover(picker, from: presenter)
    controllerPresenter(presenter, picker)
  }

  private func presentPhotos(for request: Request, from presenter: UIViewController) {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 0
    configuration.selection = .ordered
    let picker = photoPickerFactory(configuration)
    picker.delegate = self
    request.dismissal = .pending
    request.controller = picker
    configurePopover(picker, from: presenter)
    controllerPresenter(presenter, picker)
  }

  private func configurePopover(_ controller: UIViewController, from presenter: UIViewController) {
    guard let popover = controller.popoverPresentationController else { return }
    popover.sourceView = presenter.view
    popover.sourceRect = presenter.view.bounds
  }

  private func stageFiles(resolving urls: @escaping () throws -> [URL], for request: Request) {
    let policy = artifactPolicy
    let securityScope = self.securityScope
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var staged: [InkSignPdfStagedPageInput] = []
      do {
        guard !request.isCancelled() else { throw PageInputError.operationCancelled }
        for url in try urls() {
          guard !request.isCancelled() else { throw PageInputError.operationCancelled }
          let input = try securityScope(url) {
            try Self.stage(
              url: url,
              requestedType: request.options.type,
              policy: policy,
              coordinateRead: true)
          }
          request.retainStagedURL(input.url, policy: policy)
          staged.append(input)
        }
        self?.complete(request, with: .success(staged))
      } catch {
        policy.deleteURLs(request.takeStagedURLs())
        self?.complete(request, with: .failure(Self.stableError(error)))
      }
    }
  }

  func finishPhotoPicking(itemProviders: [NSItemProvider], from picker: PHPickerViewController) {
    guard let request = activeRequest, request.awaitingSelection,
          request.controller === picker else { return }
    Self.finishSelection(request, using: controllerDismisser)
    stagePhotos(itemProviders, for: request)
  }

  private func stagePhotos(_ itemProviders: [NSItemProvider], for request: Request) {
    guard !itemProviders.isEmpty else {
      complete(request, with: .success([]))
      return
    }
    let policy = artifactPolicy
    let group = DispatchGroup()
    let lock = NSLock()
    var staged = Array<InkSignPdfStagedPageInput?>(repeating: nil, count: itemProviders.count)
    var firstError: Error?
    for (index, provider) in itemProviders.enumerated() {
      group.enter()
      guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
        lock.lock()
        if firstError == nil { firstError = PageInputError.unreadableItem }
        lock.unlock()
        group.leave()
        continue
      }
      provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
        [weak self] temporaryURL, error in
        defer { group.leave() }
        guard let self, !request.isCancelled() else { return }
        do {
          guard let temporaryURL else {
            throw error ?? PageInputError.unreadableItem
          }
          let input = try Self.stage(url: temporaryURL, requestedType: .image, policy: policy)
          request.retainStagedURL(input.url, policy: policy)
          lock.lock()
          staged[index] = input
          lock.unlock()
        } catch {
          lock.lock()
          if firstError == nil { firstError = Self.stableError(error) }
          lock.unlock()
        }
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self else {
        policy.deleteURLs(request.takeStagedURLs())
        return
      }
      if request.isCancelled() {
        self.cleanup(request.takeStagedURLs())
        return
      }
      lock.lock()
      let error = firstError
      let ordered = staged.compactMap { $0 }
      lock.unlock()
      guard error == nil, ordered.count == itemProviders.count else {
        self.complete(request, with: .failure(error ?? PageInputError.unreadableItem))
        return
      }
      self.complete(request, with: .success(ordered))
    }
  }

  private func complete(_ request: Request, with result: Result<[InkSignPdfStagedPageInput], Error>) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in self?.complete(request, with: result) }
      return
    }
    guard activeRequest === request else {
      cleanup(request.takeStagedURLs())
      return
    }
    Self.finishSelection(request, using: controllerDismisser) {
      guard self.activeRequest === request else {
        self.cleanup(request.takeStagedURLs())
        return
      }
      self.activeRequest = nil
      let outcome: Result<[InkSignPdfStagedPageInput], Error> = request.isCancelled()
        ? .failure(PageInputError.operationCancelled) : result
      if case .failure = outcome {
        self.cleanup(request.takeStagedURLs(), then: {
          request.completion(outcome)
        })
      } else {
        _ = request.takeStagedURLs()
        request.completion(outcome)
      }
    }
  }

  private func cleanup(_ urls: [URL], then completion: (() -> Void)? = nil) {
    guard !urls.isEmpty else {
      if let completion {
        if Thread.isMainThread {
          completion()
        } else {
          DispatchQueue.main.async(execute: completion)
        }
      }
      return
    }
    let policy = artifactPolicy
    if Thread.isMainThread {
      DispatchQueue.global(qos: .utility).async {
        policy.deleteURLs(urls)
        if let completion {
          DispatchQueue.main.async(execute: completion)
        }
      }
    } else {
      policy.deleteURLs(urls)
      if let completion {
        DispatchQueue.main.async(execute: completion)
      }
    }
  }

  private static func localURL(from source: String) throws -> URL {
    try DocumentCore.localSource(source)
  }

  private static func stage(
    url: URL,
    requestedType: InkSignPdfPageInputType?,
    policy: InkSignPdfCacheArtifactPolicy,
    coordinateRead: Bool = false
  ) throws -> InkSignPdfStagedPageInput {
    var destination: URL?
    do {
      let allocated = try policy.allocateStagedInput()
      destination = allocated
      try FileManager.default.removeItem(at: allocated)
      if coordinateRead {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
          readingItemAt: url,
          options: [],
          error: &coordinationError) { coordinatedURL in
            do {
              try FileManager.default.copyItem(at: coordinatedURL, to: allocated)
            } catch {
              copyError = error
            }
          }
        if let copyError { throw copyError }
        if let coordinationError { throw coordinationError }
      } else {
        try FileManager.default.copyItem(at: url, to: allocated)
      }
    } catch {
      if let destination {
        policy.deleteExact(destination)
      }
      throw PageInputError.unreadableItem
    }
    do {
      guard let destination else { throw PageInputError.unreadableItem }
      let type = try resolveType(at: destination, requestedType: requestedType)
      return InkSignPdfStagedPageInput(url: destination, type: type)
    } catch {
      if let destination { policy.deleteExact(destination) }
      throw stableError(error)
    }
  }

  private static func resolveType(
    at url: URL,
    requestedType: InkSignPdfPageInputType?
  ) throws -> InkSignPdfPageInputType {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw PageInputError.unreadableItem
    }
    let header = (try? handle.read(upToCount: 5)) ?? Data()
    try? handle.close()
    if header == Data("%PDF-".utf8) {
      guard requestedType != .image else { throw PageInputError.unsupportedContent }
      return .pdf
    }
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(imageSource) > 0 else {
      throw PageInputError.unsupportedContent
    }
    guard requestedType != .pdf else { throw PageInputError.unsupportedContent }
    return .image
  }

  private static func stableError(_ error: Error) -> Error {
    if let error = error as? PageInputError { return error }
    return PageInputError.unreadableItem
  }

}

extension InkSignPdfPageInputCoordinator: UIDocumentPickerDelegate {
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let request = activeRequest, request.awaitingSelection,
          request.controller === controller else { return }
    complete(request, with: .success([]))
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let request = activeRequest, request.awaitingSelection,
          request.controller === controller else { return }
    Self.finishSelection(request, using: controllerDismisser)
    stageFiles(resolving: { urls }, for: request)
  }
}

extension InkSignPdfPageInputCoordinator: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    finishPhotoPicking(itemProviders: results.map(\.itemProvider), from: picker)
  }
}

private extension InkSignPdfCacheArtifactPolicy {
  func deleteURLs(_ urls: [URL]) {
    urls.forEach(deleteExact)
  }
}
