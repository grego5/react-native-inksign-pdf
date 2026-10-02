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
      }
    }
  }

  func addPages(options: AddPagesOptions?) throws -> Promise<AddPagesResult> {
    let settlement = InkSignPdfOperationPromise<AddPagesResult>()
    let promise = settlement.promise
    performOnMain {
      let requestedImageSize = options?.imagePageSize.map {
        CGSize(width: CGFloat($0.width), height: CGFloat($0.height))
      }
      guard let context = self.beginStructuralOperation(settlement: settlement,
                                                       requiresDocument: false) else { return }
      let inputOptions = InkSignPdfPageInputOptions(
        type: options?.type.map { InkSignPdfPageInputType(rawValue: $0.stringValue) },
        sources: options?.sources)
      self.pageInputCoordinator.stage(options: inputOptions) { [weak self] result in
        guard let self else {
          context.coordinator.settle(context.operation, succeeded: false)
          context.coordinator.stagedCleanup(result)
          settlement.reject(MutablePageError.operationCancelled)
          return
        }
        switch result {
        case .failure(let error):
          self.finishStructuralFailure(context, error: error, settlement: settlement)
        case .success(let staged):
          guard !staged.isEmpty else {
            guard self.documentCoordinator.isCurrent(context.operation) else {
              self.documentCoordinator.settle(context.operation, succeeded: false)
              settlement.reject(MutablePageError.operationCancelled)
              return
            }
            let info = (try? self.currentPageInfo()).map { self.toPublicPageInfo($0) }
            if let info {
              self.documentCoordinator.settle(context.operation, succeeded: true)
              settlement.resolve(AddPagesResult(pageInfo: info, addedPageCount: 0))
            } else {
              self.documentCoordinator.settle(context.operation, succeeded: true)
              settlement.resolve(AddPagesResult(pageInfo: nil, addedPageCount: 0))
            }
            return
          }
          guard self.prepareStructuralMutation(context, settlement: settlement) else {
            self.documentCoordinator.releaseStagedInputs(staged)
            return
          }
          self.assembleStructuralCandidate(context,
                                           staged: staged,
                                           command: .append(activePage: options?.activePage ?? .current),
                                           imageGeometry: requestedImageSize.map {
                                             PageGeometry(mediaBox: CGRect(origin: .zero, size: $0), rotation: 0)
                                           },
                                           imageTargetDpi: options?.targetDpi,
                                           imageJpegQuality: options?.jpegQuality,
                                           settlement: settlement) { pageInfo, count in
            settlement.resolve(AddPagesResult(pageInfo: pageInfo,
                                               addedPageCount: Double(count)))
          }
        }
      }
    }
    return promise
  }

  func removePage() throws -> Promise<PageInfo> {
    let settlement = InkSignPdfOperationPromise<PageInfo>()
    let promise = settlement.promise
    performOnMain {
      guard let state = self.documentCoordinator.document else {
        promise.reject(withError: MutablePageError.notReady)
        return
      }
      guard state.pages.count > 1 else {
        promise.reject(withError: MutablePageError.lastPageRequired)
        return
      }
      guard let context = self.beginStructuralOperation(settlement: settlement) else { return }
      guard self.prepareStructuralMutation(context, settlement: settlement) else { return }
      self.assembleStructuralCandidate(context,
                                       staged: [],
                                       command: .remove,
                                       settlement: settlement) { pageInfo, _ in
        settlement.resolve(pageInfo)
      }
    }
    return promise
  }

  func movePage(pageIndex: Double) throws -> Promise<PageInfo> {
    let settlement = InkSignPdfOperationPromise<PageInfo>()
    let promise = settlement.promise
    performOnMain {
      guard let context = self.beginStructuralOperation(settlement: settlement) else { return }
      guard pageIndex < Double(context.pages.count) else {
        self.documentCoordinator.settle(context.operation, succeeded: false)
        settlement.reject(MutablePageError.invalidPageIndex)
        return
      }
      let destination = Int(pageIndex)
      let order: InkSignPdfDocumentCoordinator.PageOrder
      do {
        order = try InkSignPdfDocumentCoordinator.pageOrder(
          current: context.pages,
          activePageID: context.activePageID,
          mutation: .moveActive(to: destination))
      } catch {
        self.finishStructuralFailure(context, error: error, settlement: settlement)
        return
      }
      if !order.changed {
        self.documentCoordinator.settle(context.operation, succeeded: true)
        if let pageInfo = try? self.currentPageInfo() {
          settlement.resolve(self.toPublicPageInfo(pageInfo))
        } else {
          settlement.reject(MutablePageError.notReady)
        }
        return
      }
      guard self.prepareStructuralMutation(context, settlement: settlement) else { return }
      self.assembleStructuralCandidate(context,
                                       staged: [],
                                       command: .move(to: destination),
                                       settlement: settlement) { pageInfo, _ in
        settlement.resolve(pageInfo)
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

  private func beginStructuralOperation<T>(settlement: InkSignPdfOperationPromise<T>,
                                           requiresDocument: Bool = true) -> StructuralContext? {
    guard !disposed else {
      settlement.reject(MutablePageError.operationCancelled)
      return nil
    }
    let oldState = documentCoordinator.document
    guard (oldState.map { _ in true } ?? false) || !requiresDocument else {
      settlement.reject(MutablePageError.notReady)
      return nil
    }
    guard !hasDrawingTransaction else {
      settlement.reject(MutablePageError.activeInkGesture)
      return nil
    }
    guard let operation = documentCoordinator.admit(.structural) else {
      settlement.reject(MutablePageError.operationInProgress)
      return nil
    }
    guard documentCoordinator.registerCancellation(for: operation, handler: {
      settlement.reject(MutablePageError.operationCancelled)
    }) else {
      settlement.reject(MutablePageError.operationCancelled)
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
                                             settlement: InkSignPdfOperationPromise<T>) -> Bool {
    guard documentCoordinator.isCurrent(context.operation) else {
      settlement.reject(MutablePageError.operationCancelled)
      return false
    }
    guard !hasDrawingTransaction else {
      finishStructuralFailure(context, error: MutablePageError.activeInkGesture, settlement: settlement)
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
    imageTargetDpi: Double? = nil,
    imageJpegQuality: Double? = nil,
    settlement: InkSignPdfOperationPromise<T>,
    resolve: @escaping (PageInfo, Int) -> Void
  ) {
    let coordinator = context.coordinator
    let input = InkSignPdfDocumentCoordinator.StructuralInput(
      operation: context.operation,
      document: context.oldState,
      pages: context.pages,
      activePageID: context.activePageID,
      activePageIndex: context.activePageIndex,
      imageGeometry: imageGeometry ?? context.activeGeometry,
      imageTargetDpi: imageTargetDpi,
      imageJpegQuality: imageJpegQuality)
    coordinator.pdfQueue.async { [weak self] in
      defer { coordinator.releaseStagedInputs(staged) }
      do {
        let candidate = try coordinator.assembleCandidate(input, staged: staged, command: command)
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.disposed else {
            coordinator.discardCandidate(candidate)
            coordinator.settle(context.operation, succeeded: false)
            settlement.reject(MutablePageError.operationCancelled)
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
            settlement.reject(MutablePageError.operationCancelled)
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
            settlement.reject(MutablePageError.operationCancelled)
            return
          }
          self.finishStructuralFailure(context,
                                       error: coordinator.isCurrent(context.operation)
                                         ? error : MutablePageError.operationCancelled,
                                       settlement: settlement)
        }
      }
    }
  }

  private func finishStructuralFailure<T>(_ context: StructuralContext,
                                          error: Error,
                                          settlement: InkSignPdfOperationPromise<T>) {
    let isCurrent = documentCoordinator.isCurrent(context.operation)
    if isCurrent {
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
    settlement.reject(isCurrent ? error : MutablePageError.operationCancelled)
  }

  private func restoreStructuralPresentation(_ state: InkSignPdfDocumentState,
                                             generation: UInt64,
                                             viewport: Viewport?,
                                             wasEditing: Bool) {
    let page = state.activePage
    textInteractionOverlay.clearPlacementRules()
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
    textInteractionOverlay.clearPlacementRules()
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
