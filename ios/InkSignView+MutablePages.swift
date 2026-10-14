import CoreGraphics
import Foundation
import PDFKit
import NitroModules
import UIKit

extension InkSignView {
  private struct StructuralPresentation {
    let document: InkSignPdfDocumentState?
    let generation: UInt64
    let pageID: UUID?
    let pageIndex: Int
    let geometry: PageGeometry
    let viewport: Viewport?
  }

  private func structuralPresentation(requiresDocument: Bool = true,
                                      cancelInk: Bool = false) throws -> StructuralPresentation {
    guard !disposed else { throw MutablePageError.operationCancelled }
    let state = documentCoordinator.document
    guard state != nil || !requiresDocument else { throw MutablePageError.notReady }
    if cancelInk { cancelActiveStroke() }
    guard !hasDrawingTransaction else { throw MutablePageError.activeInkGesture }
    return StructuralPresentation(document: state, generation: documentCoordinator.generation,
      pageID: viewerDocument?.activePageID, pageIndex: viewerDocument?.activePageIndex ?? 0,
      geometry: PageGeometry(mediaBox: CGRect(origin: .zero,
        size: viewerDocument?.activePage.geometry.displaySize ?? CGSize(width: 595.28, height: 841.89)), rotation: 0),
      viewport: try? interaction.viewport.currentViewportSnapshot())
  }

  private func suspendStructuralPresentation() {
    interaction.cancelPresentation()
    interaction.suspendStructural()
  }

  private func restoreStructuralPresentation<T>(_ context: StructuralPresentation, error: Error,
                                                settlement: InkSignPdfOperationPromise<T>) {
    guard !disposed, documentCoordinator.generation == context.generation else {
      settlement.reject(MutablePageError.operationCancelled)
      return
    }
    if let state = documentCoordinator.document {
      installStructuralPresentation(state, generation: context.generation,
        viewport: context.viewport, selectedPageID: context.pageID) { outcome in
        if case .failure(let presentationError) = outcome { settlement.reject(presentationError) }
        else { settlement.reject(error) }
      }
    } else {
      interaction.resumePresentation()
      settlement.reject(error)
    }
  }

  func addPages(options: AddPagesOptions?) throws -> Promise<AddPagesResult> {
    enqueueViewerCommand {
      let context = try self.structuralPresentation(requiresDocument: false)
      let geometry = try options?.imagePageSize.map { try HybridInkSignDocument.imageGeometry($0) }
        ?? context.geometry
      let result = InkSignPdfOperationPromise<AddPagesResult>()
      let coordinator = self.documentCoordinator
      let input = InkSignPdfPageInputOptions(
        type: options?.type.map { $0 == .pdf ? .pdf : .image }, sources: options?.sources)
      self.pageInputCoordinator.stage(options: input) { [weak self] stagedResult in
        guard let self, !self.disposed, coordinator.generation == context.generation else {
          if case .success(let staged) = stagedResult {
            coordinator.pdfQueue.async { coordinator.releaseStagedInputs(staged) }
          }
          result.reject(MutablePageError.operationCancelled)
          return
        }
        switch stagedResult {
        case .failure(let error): result.reject(error)
        case .success(let staged):
          guard !staged.isEmpty else {
            let info = (try? self.currentPageInfo()).map { self.toPublicPageInfo($0) }
            result.resolve(AddPagesResult(pageInfo: info, addedPageCount: 0))
            return
          }
          guard !self.hasDrawingTransaction else {
            coordinator.pdfQueue.async { coordinator.releaseStagedInputs(staged) }
            result.reject(MutablePageError.activeInkGesture)
            return
          }
          self.suspendStructuralPresentation()
          self.documentCore.commitStagedPages(staged, command: .append,
            generation: context.generation, targetPageID: context.pageID,
            imageGeometry: geometry, targetDpi: options?.targetDpi,
            jpegQuality: options?.jpegQuality, tag: options?.tag).then { [weak self] commit in
            guard let self, !self.disposed,
                  self.documentCoordinator.generation == commit.generation,
                  self.documentCoordinator.document === commit.document else {
              result.reject(MutablePageError.operationCancelled)
              return
            }
            let selected: UUID
            switch options?.activePage ?? .current {
            case .current: selected = context.pageID ?? commit.document.pages[0].id
            case .firstadded: selected = commit.document.pages[context.document?.pages.count ?? 0].id
            case .lastadded: selected = commit.document.pages.last!.id
            }
            self.installStructuralPresentation(commit.document, generation: commit.generation,
              viewport: context.viewport, selectedPageID: selected) { outcome in
              switch outcome {
              case .success(let info):
                self.emitPageState()
                result.resolve(AddPagesResult(pageInfo: info, addedPageCount: Double(commit.addedCount)))
              case .failure(let error): result.reject(error)
              }
            }
          }.catch { [weak self] error in
            guard let self else { result.reject(MutablePageError.operationCancelled); return }
            self.restoreStructuralPresentation(context, error: error, settlement: result)
          }
        }
      }
      return result.promise
    }
  }

  func removePage() throws -> Promise<PageInfo> {
    enqueueViewerCommand {
      let context = try self.structuralPresentation()
      let captured = context.pageID.map { InkSignPdfCorePageContext(generation: context.generation, pageID: $0) }
      _ = try self.documentCore.preflightPageMutation(index: context.pageIndex, capturedPage: captured)
      let result = InkSignPdfOperationPromise<PageInfo>()
      self.suspendStructuralPresentation()
      self.documentCore.mutatePage(index: context.pageIndex, capturedPage: captured).then { [weak self] in
        guard let self, !self.disposed,
              self.documentCoordinator.generation == context.generation,
              let state = self.documentCoordinator.document else {
          result.reject(MutablePageError.operationCancelled); return
        }
        let selected = state.pages[min(context.pageIndex, state.pages.count - 1)].id
        self.installStructuralPresentation(state, generation: context.generation,
          viewport: context.viewport, selectedPageID: selected) { outcome in
          switch outcome {
          case .success(let info): result.resolve(info)
          case .failure(let error): result.reject(error)
          }
        }
      }.catch { [weak self] error in
        guard let self else { result.reject(MutablePageError.operationCancelled); return }
        self.restoreStructuralPresentation(context, error: error, settlement: result)
      }
      return result.promise
    }
  }

  func movePage(pageIndex: Double) throws -> Promise<PageInfo> {
    enqueueViewerCommand {
      let context = try self.structuralPresentation()
      let destination = try HybridInkSignDocument.integer(pageIndex)
      let captured = context.pageID.map { InkSignPdfCorePageContext(generation: context.generation, pageID: $0) }
      let decision = try self.documentCore.preflightPageMutation(index: context.pageIndex,
        destination: destination, capturedPage: captured)
      if case .unchanged = decision {
        return .resolved(withResult: self.toPublicPageInfo(try self.currentPageInfo()))
      }
      let result = InkSignPdfOperationPromise<PageInfo>()
      self.suspendStructuralPresentation()
      self.documentCore.mutatePage(index: context.pageIndex, destination: destination, capturedPage: captured).then { [weak self] in
        guard let self, !self.disposed,
              self.documentCoordinator.generation == context.generation,
              let state = self.documentCoordinator.document else {
          result.reject(MutablePageError.operationCancelled); return
        }
        self.installStructuralPresentation(state, generation: context.generation,
          viewport: context.viewport, selectedPageID: context.pageID) { outcome in
          switch outcome {
          case .success(let info): result.resolve(info)
          case .failure(let error): result.reject(error)
          }
        }
      }.catch { [weak self] error in
        guard let self else { result.reject(MutablePageError.operationCancelled); return }
        self.restoreStructuralPresentation(context, error: error, settlement: result)
      }
      return result.promise
    }
  }

  func rotatePage(degrees: Double) throws -> Promise<PageInfo> {
    enqueueViewerCommand {
      guard [90.0, 180.0, 270.0].contains(degrees) else { throw MutablePageError.invalidPageRotation }
      let context = try self.structuralPresentation(cancelInk: true)
      guard let pageID = context.pageID else { throw MutablePageError.notReady }
      let captured = InkSignPdfCorePageContext(generation: context.generation, pageID: pageID)
      let result = InkSignPdfOperationPromise<PageInfo>()
      self.interaction.viewport.supersede()
      self.suspendStructuralPresentation()
      self.documentCore.rotatePage(index: context.pageIndex, degrees: Int(degrees), capturedPage: captured).then { [weak self] in
        guard let self, !self.disposed,
              self.documentCoordinator.generation == context.generation,
              let state = self.documentCoordinator.document else {
          result.reject(MutablePageError.operationCancelled); return
        }
        self.installStructuralPresentation(state, generation: context.generation,
          viewport: context.viewport, selectedPageID: pageID, fitPage: true) { outcome in
          switch outcome {
          case .success(let info): result.resolve(info)
          case .failure(let error): result.reject(error)
          }
        }
      }.catch { [weak self] error in
        guard let self else { result.reject(MutablePageError.operationCancelled); return }
        self.restoreStructuralPresentation(context, error: error, settlement: result)
      }
      return result.promise
    }
  }

  private func installStructuralPresentation(_ state: InkSignPdfDocumentState,
                                             generation: UInt64,
                                             viewport: Viewport?,
                                             selectedPageID: UUID? = nil,
                                             fitPage: Bool = false,
                                             completion: @escaping (Result<PageInfo, Error>) -> Void) {

    let selected = selectedPageID ?? viewerDocument?.activePageID
    let presented: InkSignPdfViewerDocument
    do { presented = try InkSignPdfViewerDocument(core: state, coordinator: documentCoordinator, activePageID: selected) }
    catch { completion(.failure(error)); return }
    viewerDocument = presented
    let page = presented.activePage
    let viewportRequest: ViewportRequest? = fitPage ? .fit : viewport.map {
      .focus(CGPoint(x: $0.x, y: $0.y), zoom: $0.zoom)
    }
    let request = interaction.beginPresentation(page: page, viewport: viewportRequest,
      structural: true, completion: completion)
    guard interaction.presentation === request else { return }
    invalidateOverlayTransformCache()
    textInteractionOverlay.clearPlacementRules()
    if documentView.document !== presented.document {
      documentView.document = nil
      overlayProvider.install(document: presented.document, generation: generation)
      documentView.document = presented.document
    }
    interaction.viewport.navigate(to: presented.activePDFPage)
    configureDoubleTapGestureRecognition()
    documentViewDidNavigate(to: presented.activePDFPage)
    documentView.layoutDocumentView()
    documentView.layoutIfNeeded()
    refreshActiveOverlayTransform()
    finishPagePresentationIfReady()
  }

}
