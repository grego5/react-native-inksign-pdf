import CoreGraphics
import Foundation
import PDFKit
import NitroModules

extension ViewerCanvas {
  func focusInputTarget(page: any HybridDocumentPageSpec, id: Double,
                        options: InputTargetFocusOptions?) throws -> Promise<Void> {
    guard let page = page as? HybridDocumentPage, page.core === attachedCore else { throw TextError.cancelled }
    return try enqueueInputTargetFocus(page, id: id, options: options)
  }
  func applyTextDirection() {
    performOnMain {
      guard !self.disposed else { return }
      let direction = self.textDirection ?? .auto
      self.textInteractionOverlay.setTextDirection(direction: direction)
    }
  }

  func getSessionPage(_ token: InkSignPdfModeSessionToken,
                      pageIndex: Variant_Double_TaggedPageQuery?) throws -> Promise<any HybridDocumentPageSpec> {
    try interaction.requireSession(token)
    guard let document = viewerDocument else { throw TextError.cancelled }
    let capturedPageID = pageIndex == nil ? document.activePageID : nil
    return enqueueViewerCommand(modeSession: token) {
      try self.getPageNow(query: pageIndex, modeSession: token, capturedPageID: capturedPageID)
    }
  }

  private func getPageNow(query: Variant_Double_TaggedPageQuery?,
                          modeSession: InkSignPdfModeSessionToken? = nil,
                          capturedPageID: UUID? = nil) throws -> Promise<any HybridDocumentPageSpec> {
    let core = try requireDocumentCore()
    return core.submit {
      guard !self.disposed, self.attachedCore === core else { throw TextError.cancelled }
      if let modeSession { try self.interaction.requireSession(modeSession) }
      guard let state = self.documentCoordinator.document else { throw TextError.documentNotOpen }
      let index: Int
      if let capturedPageID {
        guard let found = state.index(of: capturedPageID) else { throw TextError.cancelled }
        index = found
      } else if let query {
        index = try self.documentCore.pageIndex(query, admitted: true)
      } else {
        guard let selected = self.viewerDocument?.activePageID,
              let found = state.index(of: selected) else { throw TextError.documentNotOpen }
        index = found
      }
      let handle: any HybridDocumentPageSpec = HybridDocumentPage(core: core,
        context: .init(generation: core.coordinator.generation, pageID: state.pages[index].id),
        owner: self, modeSession: modeSession)
      return .resolved(withResult: handle)
    }
  }

  func getSelectedText() throws -> Variant__any_HybridTextHandleSpec__NullType {
    try performOnMainSync {
      guard !disposed, let selection = textInteractionOverlay.selectedText,
            let pageID = UUID(uuidString: selection.pageId) else { return .second(.null) }
      return .first(HybridTextHandle(owner: self, generation: documentCoordinator.generation,
                                    pageID: pageID, textID: selection.textId))
    }
  }

  func enqueueInputTargetFocus(_ handle: any InkSignPdfTextPageContext, id: Double,
                         options: InputTargetFocusOptions?) throws -> Promise<Void> {
    return enqueueViewerCommand(modeSession: handle.modeSession) {
      try self.performInputTargetFocus(handle, id: id, options: options)
    }
  }

  func performInputTargetFocus(_ handle: any InkSignPdfTextPageContext, id: Double,
                         options: InputTargetFocusOptions?) throws -> Promise<Void> {
    let (page, target) = try preparedTarget(handle, id: id)
    let rule = try documentCore.displayedWritingRule(target, page: page)
    let bounds = documentCore.displayedTargetBounds(target, page: page)
    let geometryRevision = page.geometryRevision
    let result = InkSignPdfOperationPromise<Void>()
    performOnMain {
      guard !self.disposed, self.attachedCore?.coordinator.generation == handle.generation else {
        result.reject(TextError.cancelled); return
      }
      let requestID = self.interaction.viewport.supersede()
      let runFocus = {
        guard !self.disposed, self.interaction.viewport.requestID == requestID,
              handle.modeSession.map(self.interaction.sessionIsCurrent) ?? true,
              self.viewerDocument?.activePage.id == handle.pageID else {
          result.reject(TextError.cancelled); return
        }
        guard self.interaction.finishInteraction(), self.interaction.viewport.requestID == requestID,
              self.attachedCore?.coordinator.generation == handle.generation,
              self.viewerDocument?.activePage.id == handle.pageID,
              page.geometryRevision == geometryRevision,
              handle.modeSession.map(self.interaction.sessionIsCurrent) ?? true else {
          result.reject(TextError.cancelled); return
        }
        guard let viewportTarget = self.interaction.viewport.fieldFocusTarget(ruleY: rule?.y ?? bounds.midY,
          horizontalFocus: rule.map { ($0.minX + $0.maxX) / 2 } ?? bounds.midX, zoom: options?.zoom ?? 2,
          verticalAnchor: options?.verticalAnchor ?? .center, edgeOffset: options?.edgeOffset ?? 0)
          else { result.reject(TextError.notReady); return }
        self.interaction.viewport.animateViewport(target: viewportTarget, modeSession: handle.modeSession) { outcome in
          switch outcome {
          case .success: result.resolve(())
          case .failure(let error): result.reject(error)
          }
        }
      }
      let navigateAndFocus = {
        guard !self.disposed, self.interaction.viewport.requestID == requestID,
              self.attachedCore?.coordinator.generation == handle.generation,
              page.geometryRevision == geometryRevision,
              handle.modeSession.map(self.interaction.sessionIsCurrent) ?? true,
              let document = self.viewerDocument,
              let index = document.index(of: handle.pageID) else {
          result.reject(TextError.cancelled); return
        }
        if index == document.activePageIndex { runFocus() }
        else {
          do {
            try self.switchPage(to: index) { outcome in
              switch outcome { case .success: runFocus(); case .failure(let error): result.reject(error) }
            }
          } catch { result.reject(error) }
        }
      }
      if let presentation = self.interaction.presentation {
        presentation.onCompletion { outcome in
          switch outcome { case .success: navigateAndFocus(); case .failure(let error): result.reject(error) }
        }
        self.finishPagePresentationIfReady()
      } else {
        navigateAndFocus()
      }
    }
    return result.promise
  }

  private func validateTextPageContext(_ handle: any InkSignPdfTextPageContext) throws {
    if let token = handle.modeSession { try interaction.requireSession(token) }
    guard !disposed, attachedCore?.coordinator.generation == handle.generation,
          viewerDocument?.pages.contains(where: { $0.id == handle.pageID }) == true else {
      throw TextError.cancelled
    }
  }

  private func preparedTarget(_ handle: any InkSignPdfTextPageContext, id: Double) throws -> (InkSignPdfPageState, InkSignPdfTextTarget) {
    try validateTextPageContext(handle)
    guard id.isFinite, id >= 1, id.rounded(.towardZero) == id, id <= 9_007_199_254_740_991,
          let document = viewerDocument,
          let page = document.pages.first(where: { $0.id == handle.pageID }) else { throw TextError.textNotFound }
    return (page, try documentCoordinator.textTarget(UInt64(id), pageID: handle.pageID))
  }

  func activeTextAnnotations() -> [InkSignPdfTextAnnotation] {
    viewerDocument?.activePage.history.content.textAnnotations ?? []
  }

  func activePageSize() -> CGSize {
    viewerDocument?.activePage.geometry.visibleBox.size ?? .zero
  }

}
