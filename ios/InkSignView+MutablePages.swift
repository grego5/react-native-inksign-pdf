import CoreGraphics
import Foundation
import PDFKit
import NitroModules
import UIKit

extension InkSignView {
  enum MutablePageError: LocalizedError {
    case notReady
    case operationInProgress
    case operationCancelled
    case activeInkGesture
    case lastPageRequired
    case invalidPageIndex
    case assemblyFailed
    case unsupportedContent
    case invalidImagePageSize

    var errorDescription: String? {
      switch self {
      case .notReady: return "document_not_ready: Open a PDF before changing pages"
      case .operationInProgress: return "operation_in_progress: Another document operation is active"
      case .operationCancelled: return "operation_cancelled: The page operation was cancelled"
      case .activeInkGesture: return "operation_in_progress: Finish the active ink gesture first"
      case .lastPageRequired: return "last_page_required: The document must retain one page"
      case .invalidPageIndex: return "invalid_page_index: The destination page index is invalid"
      case .assemblyFailed: return "pdf_mutation_failed: Unable to assemble the updated PDF"
      case .unsupportedContent: return "unsupported_content: The selected image is unreadable"
      case .invalidImagePageSize: return "invalid_image_page_size: Image page dimensions must be finite positive PDF points"
      }
    }
  }

  func addPages(options: AddPagesOptions?) throws -> Promise<AddPagesResult> {
    let promise = Promise<AddPagesResult>()
    performOnMain {
      let requestedImageSize = options?.imagePageSize.map {
        CGSize(width: CGFloat($0.width), height: CGFloat($0.height))
      }
      if let requestedImageSize,
         !requestedImageSize.width.isFinite || requestedImageSize.width <= 0 ||
         !requestedImageSize.height.isFinite || requestedImageSize.height <= 0 {
        promise.reject(withError: MutablePageError.invalidImagePageSize)
        return
      }
      guard let context = self.beginStructuralOperation(promise: promise,
                                                       requiresDocument: false) else { return }
      let inputOptions = InkSignPdfPageInputOptions(
        type: options?.type.map { InkSignPdfPageInputType(rawValue: $0.stringValue) },
        sources: options?.sources)
      self.pageInputCoordinator.stage(options: inputOptions) { [weak self] result in
        guard let self else {
          context.coordinator.settle(context.operation, succeeded: false)
          context.coordinator.stagedCleanup(result)
          promise.reject(withError: MutablePageError.operationCancelled)
          return
        }
        switch result {
        case .failure(let error):
          self.finishStructuralFailure(context, error: error, promise: promise)
        case .success(let staged):
          guard !staged.isEmpty else {
            let info = (try? self.currentPageInfo()).map { self.toPublicPageInfo($0) }
            if let info {
              self.documentCoordinator.settle(context.operation, succeeded: true)
              promise.resolve(withResult: AddPagesResult(pageInfo: info, addedPageCount: 0))
            } else {
              self.documentCoordinator.settle(context.operation, succeeded: true)
              promise.resolve(withResult: AddPagesResult(pageInfo: nil, addedPageCount: 0))
            }
            return
          }
          guard self.prepareStructuralMutation(context, promise: promise) else {
            self.documentCoordinator.releaseStagedInputs(staged)
            return
          }
          self.assembleStructuralCandidate(context,
                                           staged: staged,
                                           command: .append,
                                           imageGeometry: requestedImageSize.map {
                                             PageGeometry(mediaBox: CGRect(origin: .zero, size: $0), rotation: 0)
                                           },
                                           promise: promise) { pageInfo, count in
            promise.resolve(withResult: AddPagesResult(pageInfo: pageInfo,
                                                       addedPageCount: Double(count)))
          }
        }
      }
    }
    return promise
  }

  func removePage() throws -> Promise<PageInfo> {
    let promise = Promise<PageInfo>()
    performOnMain {
      guard let state = self.documentCoordinator.document else {
        promise.reject(withError: MutablePageError.notReady)
        return
      }
      guard state.pages.count > 1 else {
        promise.reject(withError: MutablePageError.lastPageRequired)
        return
      }
      guard let context = self.beginStructuralOperation(promise: promise) else { return }
      guard self.prepareStructuralMutation(context, promise: promise) else { return }
      self.assembleStructuralCandidate(context,
                                       staged: [],
                                       command: .remove,
                                       promise: promise) { pageInfo, _ in
        promise.resolve(withResult: pageInfo)
      }
    }
    return promise
  }

  func movePage(pageIndex: Double) throws -> Promise<PageInfo> {
    let promise = Promise<PageInfo>()
    performOnMain {
      guard let state = self.documentCoordinator.document else {
        promise.reject(withError: MutablePageError.notReady)
        return
      }
      guard pageIndex.isFinite, pageIndex >= 0,
            pageIndex.rounded(.towardZero) == pageIndex,
            pageIndex < Double(state.pages.count) else {
        promise.reject(withError: MutablePageError.invalidPageIndex)
        return
      }
      let destination = Int(pageIndex)
      guard let context = self.beginStructuralOperation(promise: promise) else { return }
      let order: InkSignPdfDocumentCoordinator.PageOrder
      do {
        order = try InkSignPdfDocumentCoordinator.pageOrder(
          current: context.pages,
          activePageID: context.activePageID,
          mutation: .moveActive(to: destination))
      } catch {
        self.finishStructuralFailure(context, error: error, promise: promise)
        return
      }
      if !order.changed {
        self.documentCoordinator.settle(context.operation, succeeded: true)
        if let pageInfo = try? self.currentPageInfo() {
          promise.resolve(withResult: self.toPublicPageInfo(pageInfo))
        } else {
          promise.reject(withError: MutablePageError.notReady)
        }
        return
      }
      guard self.prepareStructuralMutation(context, promise: promise) else { return }
      self.assembleStructuralCandidate(context,
                                       staged: [],
                                       command: .move(to: destination),
                                       promise: promise) { pageInfo, _ in
        promise.resolve(withResult: pageInfo)
      }
    }
    return promise
  }

  private final class StructuralContext {
    let operation: InkSignPdfDocumentCoordinator.OperationToken
    let coordinator: InkSignPdfDocumentCoordinator
    let oldState: InkSignPdfDocumentState?
    let pages: [InkSignPdfPageState]
    let activePageID: UUID
    let activePageIndex: Int
    let activeGeometry: PageGeometry
    let viewport: Viewport?
    let wasEditing: Bool
    var prepared = false

    init(operation: InkSignPdfDocumentCoordinator.OperationToken,
         coordinator: InkSignPdfDocumentCoordinator,
         oldState: InkSignPdfDocumentState?,
         pages: [InkSignPdfPageState], activePageID: UUID,
         activePageIndex: Int, activeGeometry: PageGeometry,
         viewport: Viewport?, wasEditing: Bool) {
      self.operation = operation
      self.coordinator = coordinator
      self.oldState = oldState
      self.pages = pages
      self.activePageID = activePageID
      self.activePageIndex = activePageIndex
      self.activeGeometry = activeGeometry
      self.viewport = viewport
      self.wasEditing = wasEditing
    }
  }

  private typealias StructuralCommand = InkSignPdfDocumentCoordinator.StructuralCommand

  private func beginStructuralOperation<T>(promise: Promise<T>,
                                           requiresDocument: Bool = true) -> StructuralContext? {
    guard !disposed else {
      promise.reject(withError: MutablePageError.operationCancelled)
      return nil
    }
    let oldState = documentCoordinator.document
    guard (oldState.map { _ in true } ?? false) || !requiresDocument else {
      promise.reject(withError: MutablePageError.notReady)
      return nil
    }
    guard !hasDrawingTransaction else {
      promise.reject(withError: MutablePageError.activeInkGesture)
      return nil
    }
    guard let operation = documentCoordinator.admit(.structural) else {
      promise.reject(withError: MutablePageError.operationInProgress)
      return nil
    }
    let viewport = try? currentViewportSnapshot()
    let wasEditing = editMode
    let pages = oldState?.pages ?? []
    let activePageID = oldState?.activePageID ?? UUID()
    let activePageIndex = oldState?.activePageIndex ?? 0
    let activeGeometry = oldState?.activePage.geometry ??
      PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 595.28, height: 841.89), rotation: 0)
    return StructuralContext(operation: operation,
                             coordinator: documentCoordinator,
                             oldState: oldState,
                             pages: pages,
                             activePageID: activePageID,
                             activePageIndex: activePageIndex,
                             activeGeometry: activeGeometry,
                             viewport: viewport,
                             wasEditing: wasEditing)
  }

  private func prepareStructuralMutation<T>(_ context: StructuralContext,
                                             promise: Promise<T>) -> Bool {
    guard documentCoordinator.isCurrent(context.operation) else {
      promise.reject(withError: MutablePageError.operationCancelled)
      return false
    }
    guard !hasDrawingTransaction else {
      finishStructuralFailure(context, error: MutablePageError.activeInkGesture, promise: promise)
      return false
    }
    cancelPendingPageSwitch()
    textInteractionOverlay.finishForLifecycle()
    setInteractionMode(editing: context.wasEditing, interactionsEnabled: false)
    context.prepared = true
    return true
  }

  private func assembleStructuralCandidate<T>(
    _ context: StructuralContext,
    staged: [InkSignPdfStagedPageInput],
    command: StructuralCommand,
    imageGeometry: PageGeometry? = nil,
    promise: Promise<T>,
    resolve: @escaping (PageInfo, Int) -> Void
  ) {
    let coordinator = context.coordinator
    let input = InkSignPdfDocumentCoordinator.StructuralInput(
      operation: context.operation,
      document: context.oldState,
      pages: context.pages,
      activePageID: context.activePageID,
      activePageIndex: context.activePageIndex,
      imageGeometry: imageGeometry ?? context.activeGeometry)
    coordinator.pdfQueue.async { [weak self] in
      defer { coordinator.releaseStagedInputs(staged) }
      do {
        let candidate = try coordinator.assembleCandidate(input, staged: staged, command: command)
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.disposed else {
            coordinator.discardCandidate(candidate)
            coordinator.settle(context.operation, succeeded: false)
            promise.reject(withError: MutablePageError.operationCancelled)
            return
          }
          let previous: InkSignPdfDocumentState?
          let published: Bool
          if case nil = context.oldState {
            previous = nil
            published = coordinator.publishInitialStructural(candidate, operation: context.operation)
          } else {
            previous = coordinator.publishStructural(candidate, operation: context.operation)
            published = previous != nil
          }
          guard published else {
            coordinator.discardCandidate(candidate)
            coordinator.settle(context.operation, succeeded: false)
            promise.reject(withError: MutablePageError.operationCancelled)
            return
          }
          self.installStructuralPresentation(candidate, generation: coordinator.generation,
                                             viewport: context.viewport,
                                             wasEditing: context.wasEditing)
          if let previous { coordinator.releaseReplacedDocument(previous) }
          coordinator.settle(context.operation, succeeded: true)
          let info = (try? self.currentPageInfo()) ??
            InkSignPdfNativePageInfo(pageIndex: candidate.activePageIndex,
                                     pageCount: candidate.pages.count,
                                     geometry: candidate.activePage.geometry)
          resolve(self.toPublicPageInfo(info), candidate.pages.count - context.pages.count)
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self else {
            coordinator.settle(context.operation, succeeded: false)
            promise.reject(withError: MutablePageError.operationCancelled)
            return
          }
          self.finishStructuralFailure(context,
                                       error: coordinator.isCurrent(context.operation)
                                         ? error : MutablePageError.operationCancelled,
                                       promise: promise)
        }
      }
    }
  }

  private func finishStructuralFailure<T>(_ context: StructuralContext,
                                          error: Error,
                                          promise: Promise<T>) {
    if documentCoordinator.isCurrent(context.operation) {
      documentCoordinator.settle(context.operation, succeeded: false)
      if context.prepared, let oldState = context.oldState {
        restoreStructuralPresentation(oldState,
                                      generation: context.operation.generation,
                                      viewport: context.viewport,
                                      wasEditing: context.wasEditing)
      } else if context.prepared {
        setInteractionMode(editing: false, interactionsEnabled: true)
      }
    }
    promise.reject(withError: error)
  }

  private func restoreStructuralPresentation(_ state: InkSignPdfDocumentState,
                                             generation: UInt64,
                                             viewport: Viewport?,
                                             wasEditing: Bool) {
    let page = state.activePage
    overlayProvider.install(document: state.document, generation: generation)
    documentView.document = state.document
    documentView.go(to: page.page)
    applyStructuralViewport(viewport)
    restoreInteractionMode(wasEditing)
  }

  private func installStructuralPresentation(_ state: InkSignPdfDocumentState,
                                             generation: UInt64,
                                             viewport: Viewport?,
                                             wasEditing: Bool) {
    pageSwitchRequestID &+= 1
    pendingPageSwitchID = nil
    let page = state.activePage
    overlayProvider.install(document: state.document, generation: generation)
    documentView.document = state.document
    documentView.go(to: page.page)
    applyStructuralViewport(viewport)
    restoreInteractionMode(wasEditing)
    configureDoubleTapGestureRecognition()
    emitChange(force: true)
  }

  private func applyStructuralViewport(_ viewport: Viewport?) {
    guard let viewport else { return }
    _ = applyViewport(target: ViewportTarget(zoom: CGFloat(viewport.zoom),
                                             focus: CGPoint(x: viewport.x, y: viewport.y)))
  }

  private func restoreInteractionMode(_ wasEditing: Bool) {
    setInteractionMode(editing: wasEditing, interactionsEnabled: true)
  }
}

private extension InkSignPdfPageInputType {
  init(rawValue: String) {
    self = rawValue == "pdf" ? .pdf : .image
  }
}

private extension InkSignPdfDocumentCoordinator {
  func stagedCleanup(_ result: Result<[InkSignPdfStagedPageInput], Error>) {
    if case .success(let inputs) = result {
      releaseStagedInputs(inputs)
    }
  }
}
