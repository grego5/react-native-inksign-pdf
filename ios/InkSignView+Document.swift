import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules
import QuartzCore

extension InkSignView {
  func enqueueViewerCommand<T>(presentation: Bool = false,
                               modeSession: InkSignPdfModeSessionToken? = nil,
                               _ action: @escaping () throws -> Promise<T>) -> Promise<T> {
    let result = InkSignPdfOperationPromise<T>()
    performOnMain {
      guard !self.disposed, modeSession.map(self.interaction.sessionIsCurrent) ?? true else {
        result.reject(LoadError.cancelled); return
      }
      let id = UUID()
      let entry = ViewerCommand(id: id, presentation: presentation, modeSession: modeSession, start: { [weak self] in
        guard let self else { result.reject(LoadError.cancelled); return }
        do {
          if let modeSession { try self.interaction.requireSession(modeSession) }
          let operation = try action()
          operation.then { value in
            self.performOnMain {
              if let modeSession, !self.interaction.sessionIsCurrent(modeSession) { result.reject(LoadError.cancelled) }
              else { result.resolve(value) }
              self.finishViewerCommand(id)
            }
          }.catch { error in
            self.performOnMain { result.reject(error); self.finishViewerCommand(id) }
          }
        } catch {
          result.reject(error)
          self.finishViewerCommand(id)
        }
      }, cancel: { result.reject(LoadError.cancelled) })
      self.commandQueue.append(entry)
      self.drainViewerCommands()
    }
    return result.promise
  }

  private func drainViewerCommands() {
    guard !disposed, runningCommand == nil, !commandQueue.isEmpty else { return }
    let entry = commandQueue.removeFirst()
    runningCommand = entry
    entry.start()
  }

  private func finishViewerCommand(_ id: UUID) {
    guard runningCommand?.id == id else { return }
    runningCommand = nil
    drainViewerCommands()
  }

  func cancelPresentationCommands() {
    performOnMain {
      let retired = self.commandQueue.filter { $0.presentation }
      self.commandQueue.removeAll { $0.presentation }
      let running = self.runningCommand?.presentation == true ? self.runningCommand : nil
      self.pageNavigationRequestID &+= 1
      self.interaction.retireRequests()
      retired.forEach { $0.cancel() }
      running?.cancel()
    }
  }

  func cancelViewerCommands() {
    interaction.cancelCoordinates()
    let retired = commandQueue
    commandQueue.removeAll()
    let running = runningCommand
    runningCommand = nil
    retired.forEach { $0.cancel() }
    running?.cancel()
  }

  func close(cancelPending: Bool?) throws -> Promise<Void> {
    cancelPresentationCommands()
    if cancelPending == true {
      return try performOnMainSync {
        guard !self.disposed else { throw LoadError.cancelled }
        self.cancelViewerCommands()
        self.closePublishedDocument()
        return self.documentCore.closeViewerDocument(cancelPending: true)
      }
    }
    return enqueueViewerCommand {
      let settlement = InkSignPdfOperationPromise<Void>()
      self.documentCore.closeViewerDocument(cancelPending: false).then { _ in
        self.closePublishedDocument()
        settlement.resolve(())
      }.catch { error in settlement.reject(error) }
      return settlement.promise
    }
  }

  private func closePublishedDocument() {
    pendingOpen?.settlement.reject(LoadError.cancelled)
    pendingOpen = nil
    pageInputCoordinator.cancelPending()
    textInteractionOverlay.discardForDocumentReplacement()
    cancelActiveStroke(clearLive: false)
    interaction.cancelPresentation()
    interaction.viewport.supersede()
    pageNavigationRequestID &+= 1

    interaction.resetAvailability()
    documentView.document = nil
    viewerDocument = nil
    overlayProvider.reset()
    attachedOverlayPage = nil
    invalidateOverlayTransformCache()
    interaction.setBaseMode(ink: false, enabled: false, finish: false)
    emitChange(force: true)
  }

  func performOnMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  func performOnMainSync<T>(_ work: () throws -> T) throws -> T {
    if Thread.isMainThread { return try work() }
    var result: Result<T, Error>?
    DispatchQueue.main.sync {
      result = Result { try work() }
    }
    return try result!.get()
  }

  func open(path: String, options: ViewOpenOptions?) throws -> Promise<PageInfo> {
    let viewport = options.map { ViewportOptions(x: $0.x, y: $0.y, zoom: $0.zoom) }
    cancelPresentationCommands()
    return enqueueViewerCommand { try self.openNow(path: path, options: viewport, tag: options?.tag) }
  }

  private func openNow(path: String, options: ViewportOptions?, tag: String? = nil) throws -> Promise<PageInfo> {
    let promise = Promise<PageInfo>()
    performOnMain {
      self.loadError = nil
      self.emitChange()
      do {
        let viewport = Self.parseOpenViewport(options)
        self.beginLoad(
          path,
          zoom: viewport.zoom,
          focus: viewport.focus,
          fitToPage: viewport.fitToPage,
          tag: tag,
          promise: promise
        )
      } catch {
        self.loadError = error.localizedDescription
        self.emitChange()
        promise.reject(withError: error)
      }
    }
    return promise
  }

  func nextPage() throws {
    try performOnMainSync { try self.navigatePage(by: 1) }
  }

  func previousPage() throws {
    try performOnMainSync { try self.navigatePage(by: -1) }
  }

  private func navigatePage(by delta: Int) throws {
    guard !disposed else { throw ViewportError.cancelled }
    let current = try currentPageInfo()
    let target = min(max(current.pageIndex + delta, 0), current.pageCount - 1)
    interaction.cancelPresentation()
    pageNavigationRequestID &+= 1
    if target == current.pageIndex {
      return
    }
    let requestID = pageNavigationRequestID
    let requestGeneration = documentCoordinator.generation
    DispatchQueue.main.async { [weak self] in
      guard let self,
            !self.disposed,
            self.documentCoordinator.generation == requestGeneration,
            self.pageNavigationRequestID == requestID else { return }
      do {
        try self.switchPage(to: target, completion: self.programmaticPageSwitchCompletion())
      } catch {
        self.reportPageNavigationFailure(error)
      }
    }
  }

  func getViewport() throws -> Viewport {
    try performOnMainSync {
      guard !self.disposed else { throw ViewportError.cancelled }
      return try self.interaction.viewport.currentViewportSnapshot()
    }
  }

  func getState() throws -> DocumentState {
    try performOnMainSync {
      guard !self.disposed else { throw ViewportError.cancelled }
      return self.documentStateSnapshot()
    }
  }

  func documentStateSnapshot() -> DocumentState {
    return DocumentState(documentId: documentID.map { .second($0) } ?? .first(.null),
      pageCount: Double(documentCoordinator.document?.pages.count ?? 0), isDirty: documentCoordinator.isDirty)
  }

  func setMode(mode: InputMode, options: TextModeOptions?) throws -> any HybridModeSessionSpec {
    try performOnMainSync {
      _ = try documentCore.fonts.resolve(options?.font)
      let token = try interaction.beginSession(mode, options: options)
      return HybridModeSession(owner: self, token: token)
    }
  }

  func beginLoad(
    _ path: String,
    zoom: Double?,
    focus: CGPoint?,
    fitToPage: Bool,
    tag: String? = nil,
    promise: Promise<PageInfo>
  ) {
    guard !disposed else {
      promise.reject(withError: LoadError.cancelled)
      return
    }
    let replacedOpen = pendingOpen
    interaction.retireRequests()
    pendingOpen = nil
    interaction.resetAvailability()
    textInteractionOverlay.discardForDocumentReplacement()
    pageInputCoordinator.cancelPending()
    cancelActiveStroke(clearLive: false)
    pageNavigationRequestID &+= 1

    interaction.setBaseMode(ink: false, enabled: false, finish: false)
    textInteractionOverlay.clearPlacementRules()
    documentView.document = nil
    viewerDocument = nil
    overlayProvider.reset()
    attachedOverlayPage = nil
    invalidateOverlayTransformCache()
    emitChange(force: true)
    let requestID = UUID()
    pendingOpen = PendingOpen(id: requestID,
                              promise: promise,
                              zoom: zoom,
                              focus: focus,
                              fitToPage: fitToPage)
    replacedOpen?.settlement.reject(LoadError.cancelled)

    let sourceURL: URL
    if let fileURL = URL(string: path), fileURL.isFileURL {
      if let host = fileURL.host, !host.isEmpty, host.lowercased() != "localhost" {
        finishLoad(requestID: requestID, error: .invalidSourcePath)
        return
      }
      sourceURL = fileURL
    } else {
      sourceURL = URL(fileURLWithPath: path)
    }
    let url = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
    documentCore.open(sourceURL: url, tag: tag).then { [weak self, coordinator = documentCoordinator] candidate in
      guard let self, !self.disposed, coordinator.document === candidate,
            self.pendingOpen?.id == requestID else { return }
      self.installOpenCandidate(candidate, requestID: requestID)
    }.catch { [weak self] error in
      guard let self else { return }
      let mapped: LoadError
      if let failure = error as? InkSignPdfLoadError {
        switch failure {
        case .invalidSource: mapped = .invalidSourcePath
        case .empty: mapped = .unsupportedPdf
        case .cancelled: mapped = .cancelled
        case .failed: mapped = .pdfLoadFailed
        }
      } else if let failure = error as? InkSignPdfDocumentCandidateError, failure == .empty {
        mapped = .unsupportedPdf
      } else {
        mapped = .pdfLoadFailed
      }
      self.finishLoad(requestID: requestID, error: mapped)
    }
  }

  func installOpenCandidate(
    _ candidate: InkSignPdfDocumentState,
    requestID: UUID
  ) {
    guard var pending = pendingOpen,
          pending.id == requestID,
          pending.phase == .preparing,
          documentCoordinator.document === candidate,
          !disposed else { return }

    pending.generation = documentCoordinator.generation
    pending.phase = .installing
    pendingOpen = pending
    interaction.finishInteraction()
    pageInputCoordinator.cancelPending()
    interaction.setBaseMode(ink: false, enabled: false, finish: false)
    interaction.cancelPresentation()
    pageNavigationRequestID &+= 1

    invalidateOverlayTransformCache()
    textInteractionOverlay.clearPlacementRules()

    // PDFKit releases the old page overlays as it drops the old document.
    // The provider then retires any overlays PDFKit did not end explicitly.
    documentView.document = nil
    viewerDocument = nil
    overlayProvider.reset()
    let presented: InkSignPdfViewerDocument
    do { presented = try InkSignPdfViewerDocument(core: candidate, coordinator: documentCoordinator) }
    catch { failOpenAttempt(error: LoadError.pdfLoadFailed); return }
    viewerDocument = presented
    overlayProvider.install(document: presented.document, generation: documentCoordinator.generation)
    documentView.document = presented.document
    guard documentView.document === presented.document else {
      failOpenAttempt(error: LoadError.pdfLoadFailed)
      return
    }
    interaction.viewport.navigate(to: presented.activePDFPage)
    configureDoubleTapGestureRecognition()
    pending.phase = .awaitingReadiness
    pendingOpen = pending
    _ = completeOpenIfReady()
  }

  func finishLoad(requestID: UUID,
                  error: LoadError) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.disposed,
            let pending = self.pendingOpen,
            pending.id == requestID,
            pending.phase == .preparing else { return }
      self.failOpenAttempt(error: error, pending: pending)
    }
  }

  func isOpenPresentationCurrent(_ pending: PendingOpen) -> Bool {
    !disposed && pendingOpen?.id == pending.id &&
      (pending.generation == nil || pending.generation == documentCoordinator.generation)
  }

  func failOpenAttempt(
    error: Error,
    pending failed: PendingOpen? = nil
  ) {
    guard var pending = pendingOpen,
          pending.phase != .clearing,
          isOpenPresentationCurrent(pending),
          (failed.map { $0.id == pending.id } ?? true) else { return }
    pending.phase = .clearing
    pendingOpen = pending
    interaction.finishInteraction()
    interaction.cancelPresentation()
    pageNavigationRequestID &+= 1

    interaction.setBaseMode(ink: false, enabled: false, finish: false)
    textInteractionOverlay.clearPlacementRules()
    documentView.document = nil
    viewerDocument = nil
    overlayProvider.reset()
    attachedOverlayPage = nil
    invalidateOverlayTransformCache()
    pendingOpen = nil
    loadError = error.localizedDescription
    emitChange(force: true)
    pending.settlement.reject(error)
  }

  func configureCanvasInteraction(_ canvas: InkCanvasView) {
    let enabled = interaction.inputEnabled
    canvas.isHidden = documentCoordinator.document == nil
    canvas.isUserInteractionEnabled = enabled
    canvas.drawingGestureRecognizer.isEnabled = interaction.acceptsInkInput
  }

  func currentPageInfo() throws -> InkSignPdfNativePageInfo {
    guard let state = viewerDocument else { throw ViewportError.notReady }
    return InkSignPdfNativePageInfo(pageIndex: state.activePageIndex,
                                    pageCount: state.pages.count,
                                    geometry: state.activePage.geometry)
  }

  func toPublicPageInfo(_ info: InkSignPdfNativePageInfo) -> PageInfo {
    let event = toPageChangeEvent(info)
    let page = documentCoordinator.document!.pages[info.pageIndex]
    return PageInfo(tag: page.tag, hasInk: !page.history.content.drawing.strokes.isEmpty,
                    hasText: !page.history.content.textAnnotations.isEmpty,
                    pageIndex: Double(info.pageIndex), pageCount: Double(info.pageCount),
                    isDirty: page.history.state.isDirty, pageId: event.pageId,
                    width: event.width, height: event.height, rotation: event.rotation,
                    canUndo: event.canUndo, canRedo: event.canRedo)
  }

  func toPageChangeEvent(_ info: InkSignPdfNativePageInfo) -> PageChangeEvent {
    let displaySize = info.geometry.displaySize
    let page = documentCoordinator.document!.pages[info.pageIndex]
    let history = page.history
    return PageChangeEvent(pageId: page.id.uuidString,
                       width: Double(displaySize.width),
                       height: Double(displaySize.height),
                       rotation: Double(info.geometry.rotation),
                       canUndo: history.canUndo, canRedo: history.canRedo)
  }

  func emitPageState() {
    guard !disposed, !suppressesOpenPresentationCallbacks else { return }
    guard let document = viewerDocument else { lastPublicPage = nil; return }
    let page = document.activePage
    let size = page.geometry.displaySize
    let value = PageChangeEvent(pageId: page.id.uuidString,
      width: Double(size.width), height: Double(size.height),
      rotation: Double(page.geometry.rotation),
      canUndo: page.history.canUndo, canRedo: page.history.canRedo)
    if let previous = lastPublicPage,
       previous.pageId == value.pageId, previous.width == value.width,
       previous.height == value.height, previous.rotation == value.rotation,
       previous.canUndo == value.canUndo, previous.canRedo == value.canRedo { return }
    lastPublicPage = value
    onPageChange?(value)
  }

  /// Changes the coordinator-owned active page while keeping one PDF overlay
  /// canvas. Overlay callbacks complete the presentation handoff for the
  /// switch request that installed the target page.

}
