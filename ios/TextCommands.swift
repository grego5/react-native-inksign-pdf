import CoreGraphics
import Foundation
import PDFKit
import NitroModules

extension InkSignView {
  func loadFonts(fonts: [NamedFontSource]) throws -> Promise<Void> {
    documentCore.loadFonts(fonts)
  }

  func setTextDirection(direction: TextDirection) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      switch direction {
      case .ltr: self.documentCore.defaultDirectionRTL = false
      case .rtl: self.documentCore.defaultDirectionRTL = true
      case .auto: self.documentCore.defaultDirectionRTL = nil
      }
      self.textInteractionOverlay.setTextDirection(direction: direction)
    }
  }

  func getPage(pageIndex: Variant_Double_TaggedPageQuery?) throws -> Promise<any HybridAnalyzedPageSpec> {
    enqueueViewerCommand { self.getPageNow(query: pageIndex) }
  }

  func getPageIdsByTag(tag: String) throws -> [String] {
    try documentCore.onOwnerSync { try documentCore.pageIDs(tag: tag) }
  }

  func getSessionPage(_ token: InkSignPdfModeSessionToken,
                      pageIndex: Variant_Double_TaggedPageQuery?) throws -> Promise<any HybridAnalyzedPageSpec> {
    try interaction.requireSession(token)
    guard let document = viewerDocument else { throw TextError.cancelled }
    let capturedPageID = pageIndex == nil ? document.activePageID : nil
    return enqueueViewerCommand(modeSession: token) {
      self.getPageNow(query: pageIndex, modeSession: token, capturedPageID: capturedPageID)
    }
  }

  private func getPageNow(query: Variant_Double_TaggedPageQuery?,
                          modeSession: InkSignPdfModeSessionToken? = nil,
                          capturedPageID: UUID? = nil) -> Promise<any HybridAnalyzedPageSpec> {
    documentCore.submit {
      guard !self.disposed else { throw TextError.cancelled }
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
      let handle: any HybridAnalyzedPageSpec = HybridAnalyzedPage(owner: self,
        generation: self.documentCoordinator.generation, pageID: state.pages[index].id,
        modeSession: modeSession)
      return .resolved(withResult: handle)
    }
  }

  func resolvePreparedText(_ handle: HybridAnalyzedPage, options: InputTargetResolutionOptions) throws -> Double {
    try validateTextPageContext(handle)
    return try documentCore.resolveText(InkSignPdfCorePageContext(generation: handle.generation,
      pageID: handle.pageID), options: options)
  }

  func getSelectedText() throws -> Variant__any_HybridTextHandleSpec__NullType {
    try performOnMainSync {
      guard !disposed, let selection = textInteractionOverlay.selectedText,
            let pageID = UUID(uuidString: selection.pageId) else { return .second(.null) }
      return .first(HybridTextHandle(owner: self, generation: documentCoordinator.generation,
                                    pageID: pageID, textID: selection.textId))
    }
  }

  func preparedTextValue(_ handle: any InkSignPdfTextPageContext, id: Double) throws -> String {
    let (page, target) = try preparedTarget(handle, id: id)
    return textInteractionOverlay.preparedDraftText(id: target.id, pageID: page.id)
      ?? page.history.text(for: target.id)?.text
      ?? target.embeddedValue
  }

  func setPreparedTextValue(_ handle: any InkSignPdfTextPageContext, id: Double, text: String,
                            options: TextAnnotationOptions? = nil) throws {
    let (_, target) = try preparedTarget(handle, id: id)
    let context = InkSignPdfCorePageContext(generation: handle.generation, pageID: handle.pageID)
    if text.isEmpty {
      textInteractionOverlay.clearPreparedDraft(id: target.id, pageID: handle.pageID)
    } else {
      if try textInteractionOverlay.setPreparedDraftText(id: target.id, pageID: handle.pageID,
                                                         text: text, options: options) { return }
    }
    try documentCore.setTextValue(context, id: id, text: text, options: options)
  }

  func setPreparedTextOptions(_ handle: any InkSignPdfTextPageContext, id: Double,
                              options: TextAnnotationOptions) throws {
    let (_, target) = try preparedTarget(handle, id: id)
    if try textInteractionOverlay.setPreparedDraftOptions(id: target.id, pageID: handle.pageID, options: options) { return }
    try documentCore.setTextOptions(InkSignPdfCorePageContext(generation: handle.generation,
      pageID: handle.pageID), id: id, options: options)
  }

  func preparedInputTarget(_ handle: any InkSignPdfTextPageContext, id: Double) throws -> InputTarget {
    let (page, target) = try preparedTarget(handle, id: id)
    let draft = textInteractionOverlay.preparedDraftText(id: target.id, pageID: page.id)
    let annotation = page.history.text(for: target.id)
    let value = draft ?? annotation?.text ?? target.embeddedValue
    let source: TextValueSource = draft != nil || annotation != nil ? .annotation
      : (!target.embeddedValue.isEmpty ? .embedded : .empty)
    let bounds = documentCore.displayedTargetBounds(target, page: page)
    return InputTarget(id: Double(target.id), value: value, fieldName: target.fieldName,
      bounds: TextAnnotationBounds(x: Double(bounds.minX), y: Double(bounds.minY),
        width: Double(bounds.width), height: Double(bounds.height)),
      valueSource: source)
  }

  func adjustPreparedTextSize(_ handle: any InkSignPdfTextPageContext, id: Double, delta: Double) throws -> Double {
    let (page, target) = try preparedTarget(handle, id: id)
    let size = textInteractionOverlay.preparedFontSize(id: target.id, pageID: page.id)
      ?? page.history.text(for: target.id).map { Double($0.fontSize) }
      ?? target.options.fontSize ?? textInteractionOverlay.preparedDefaultFontSize
    let adjusted = textInteractionOverlay.adjustedFontSize(size, delta: delta)
    if adjusted != size {
      let options = TextAnnotationOptions(untracked: nil, font: nil, fontSize: adjusted, color: nil, direction: nil,
        maxLines: nil, alignment: nil, verticalAnchor: nil)
      try setPreparedTextOptions(handle, id: id, options: options)
    }
    return adjusted
  }

  func preparedTextEntries(_ handle: any InkSignPdfTextPageContext) throws -> [InputTarget] {
    try validateTextPageContext(handle)
    return try documentCoordinator.textTargets(for: handle.pageID).map {
      try preparedInputTarget(handle, id: Double($0.id))
    }
  }

  func focusPreparedText(_ handle: any InkSignPdfTextPageContext, id: Double,
                         options: InputTargetFocusOptions?) throws -> Promise<Void> {
    return enqueueViewerCommand(presentation: true, modeSession: handle.modeSession) {
      try self.focusPreparedTextNow(handle, id: id, options: options)
    }
  }

  private func focusPreparedTextNow(_ handle: any InkSignPdfTextPageContext, id: Double,
                         options: InputTargetFocusOptions?) throws -> Promise<Void> {
    let (page, target) = try preparedTarget(handle, id: id)
    let rule = try documentCore.displayedWritingRule(target, page: page)
    let bounds = documentCore.displayedTargetBounds(target, page: page)
    let geometryRevision = page.geometryRevision
    let result = InkSignPdfOperationPromise<Void>()
    performOnMain {
      guard !self.disposed, self.documentCoordinator.generation == handle.generation else {
        result.reject(TextError.cancelled); return
      }
      guard let document = self.viewerDocument,
            let index = document.index(of: handle.pageID) else { result.reject(TextError.cancelled); return }
      let requestID = self.interaction.viewport.supersede()
      let runFocus = {
        guard !self.disposed, self.interaction.viewport.requestID == requestID,
              handle.modeSession.map(self.interaction.sessionIsCurrent) ?? true,
              self.viewerDocument?.activePage.id == handle.pageID else {
          result.reject(TextError.cancelled); return
        }
        guard self.interaction.finishInteraction(), self.interaction.viewport.requestID == requestID,
              self.documentCoordinator.generation == handle.generation,
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
      if index == document.activePageIndex { runFocus() }
      else {
        do {
          try self.switchPage(to: index) { outcome in
            switch outcome { case .success: runFocus(); case .failure(let error): result.reject(error) }
          }
        } catch { result.reject(error) }
      }
    }
    return result.promise
  }

  private func validateTextPageContext(_ handle: any InkSignPdfTextPageContext) throws {
    if let token = handle.modeSession { try interaction.requireSession(token) }
    guard !disposed, documentCoordinator.generation == handle.generation,
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

  func appendTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.documentCoordinator.generation == generation,
          let state = viewerDocument,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    try? documentCore.appendText(annotation,
      context: InkSignPdfCorePageContext(generation: generation, pageID: state.activePage.id))
  }

  func appendTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageID: UUID
  ) throws {
    guard !disposed,
          documentCoordinator.generation == generation,
          let state = viewerDocument,
          let target = state.pages.first(where: { $0.id == pageID }) else {
      throw TextError.cancelled
    }
    let targetIsActive = state.activePageID == pageID
    if targetIsActive { cancelActiveStroke() }
    try documentCore.appendText(annotation,
      context: InkSignPdfCorePageContext(generation: generation, pageID: target.id))
  }

  func replaceTextAnnotation(_ before: InkSignPdfTextAnnotation,
                             with after: InkSignPdfTextAnnotation,
                             type: InkSignPdfPageContentActionType,
                             generation: UInt64, pageID: UUID) throws {
    guard !disposed, documentCoordinator.generation == generation,
          let page = viewerDocument?.pages.first(where: { $0.id == pageID }) else {
      throw TextError.cancelled
    }
    try documentCore.replaceText(before, with: after, type: type,
      context: InkSignPdfCorePageContext(generation: generation, pageID: page.id))
  }

  func removeTextAnnotation(_ annotation: InkSignPdfTextAnnotation,
                            generation: UInt64, pageID: UUID) throws {
    guard !disposed, documentCoordinator.generation == generation,
          let page = viewerDocument?.pages.first(where: { $0.id == pageID }) else {
      throw TextError.cancelled
    }
    try documentCore.removeText(annotation,
      context: InkSignPdfCorePageContext(generation: generation, pageID: page.id))
  }

  func replaceTextAnnotation(
    _ before: InkSignPdfTextAnnotation,
    with after: InkSignPdfTextAnnotation,
    type: InkSignPdfPageContentActionType,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.documentCoordinator.generation == generation,
          let state = viewerDocument,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    try? documentCore.replaceText(before, with: after, type: type,
      context: InkSignPdfCorePageContext(generation: generation, pageID: state.activePage.id))
  }

  func removeTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.documentCoordinator.generation == generation,
          let state = viewerDocument,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    try? documentCore.removeText(annotation,
      context: InkSignPdfCorePageContext(generation: generation, pageID: state.activePage.id))
  }
}
