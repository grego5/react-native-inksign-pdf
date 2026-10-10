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
        return Promise<Void>.resolved()
      }
    }
    return enqueueViewerCommand {
      self.closePublishedDocument()
      return Promise<Void>.resolved()
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

    documentCoordinator.closeDocument()
    interaction.resetAvailability()
    documentID = nil
    documentView.document = nil
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

  func open(path: String, options: ViewportOptions?) throws -> Promise<PageInfo> {
    cancelPresentationCommands()
    return enqueueViewerCommand { try self.openNow(path: path, options: options) }
  }

  private func openNow(path: String, options: ViewportOptions?) throws -> Promise<PageInfo> {
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

  func hasInk() throws -> Bool {
    try performOnMainSync {
      guard !self.disposed,
            let page = self.documentCoordinator.document?.activePage else { return false }
      return !page.history.content.drawing.strokes.isEmpty
    }
  }

  func setMode(mode: InputMode, options: TextModeOptions?) throws -> any HybridModeSessionSpec {
    try performOnMainSync {
      let token = try interaction.beginSession(mode, options: options)
      return HybridModeSession(owner: self, token: token)
    }
  }

  func beginLoad(
    _ path: String,
    zoom: Double?,
    focus: CGPoint?,
    fitToPage: Bool,
    promise: Promise<PageInfo>
  ) {
    guard !disposed else {
      promise.reject(withError: LoadError.cancelled)
      return
    }
    let replacedOpen = pendingOpen
    interaction.retireRequests()
    pendingOpen = nil
    guard let operation = documentCoordinator.admit(.open) else {
      replacedOpen?.settlement.reject(LoadError.cancelled)
      promise.reject(withError: LoadError.operationInProgress)
      return
    }
    interaction.resetAvailability()
    textInteractionOverlay.discardForDocumentReplacement()
    pageInputCoordinator.cancelPending()
    cancelActiveStroke(clearLive: false)
    pageNavigationRequestID &+= 1

    interaction.setBaseMode(ink: false, enabled: false, finish: false)
    textInteractionOverlay.clearPlacementRules()
    documentView.document = nil
    overlayProvider.reset()
    documentID = nil
    documentCoordinator.clearDocument()
    attachedOverlayPage = nil
    invalidateOverlayTransformCache()
    emitChange(force: true)
    pendingOpen = PendingOpen(operation: operation,
                              promise: promise,
                              zoom: zoom,
                              focus: focus,
                              fitToPage: fitToPage)
    replacedOpen?.settlement.reject(LoadError.cancelled)

    let sourceURL: URL
    if let fileURL = URL(string: path), fileURL.isFileURL {
      if let host = fileURL.host, !host.isEmpty, host.lowercased() != "localhost" {
        finishLoad(operation: operation, error: .invalidSourcePath)
        return
      }
      sourceURL = fileURL
    } else {
      sourceURL = URL(fileURLWithPath: path)
    }
    let url = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
    documentCoordinator.pdfQueue.async { [weak self, coordinator = documentCoordinator] in
      guard let self else { return }
      var workingURL: URL?
      var ownsWorkingURL = false
      defer {
        if !ownsWorkingURL, let workingURL { coordinator.discardArtifact(workingURL) }
      }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
        self.finishLoad(operation: operation, error: .invalidSourcePath); return
      }
      guard let sourceData = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
        self.finishLoad(operation: operation, error: .pdfLoadFailed); return
      }
      do {
        let allocated = try self.artifactPolicy.allocateWorkingSource()
        guard coordinator.registerPendingArtifact(allocated, for: operation) else {
          self.artifactPolicy.deleteExact(allocated)
          self.finishLoad(operation: operation, error: .cancelled)
          return
        }
        workingURL = allocated
        if sourceData.starts(with: [0xff, 0xd8, 0xff]) {
          let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 595.28, height: 841.89),
                                      rotation: 0)
          let imagePage = try InkSignPdfMutablePageImageEncoder.encode(url, geometry: geometry)
          let document = PDFDocument()
          document.insert(imagePage, at: 0)
          guard let data = document.dataRepresentation() else { throw LoadError.pdfLoadFailed }
          try data.write(to: allocated, options: .atomic)
        } else {
          try sourceData.write(to: allocated, options: .atomic)
        }
      } catch {
        self.finishLoad(operation: operation, error: .pdfLoadFailed); return
      }
      guard let workingURL else {
        self.finishLoad(operation: operation, error: .pdfLoadFailed); return
      }
      let loadedCandidate: InkSignPdfDocumentCandidate
      do {
        loadedCandidate = try InkSignPdfDocumentCandidateLoader.load(url: workingURL)
      } catch let candidateError as InkSignPdfDocumentCandidateError {
        let loadError: LoadError
        switch candidateError {
        case .empty:
          loadError = .unsupportedPdf
        case .unreadable, .invalidGeometry:
          loadError = .pdfLoadFailed
        }
        self.finishLoad(operation: operation, error: loadError); return
      } catch {
        self.finishLoad(operation: operation, error: .pdfLoadFailed); return
      }
      let loadedDocument = loadedCandidate.document
      let loadedPages = loadedCandidate.pages
      ownsWorkingURL = true
      DispatchQueue.main.async { [weak self, coordinator] in
        guard let self, !self.disposed,
              coordinator.isCurrent(operation),
              self.pendingOpen?.operation.id == operation.id else {
          coordinator.discardArtifact(workingURL)
          return
        }
        let newDocument = InkSignPdfDocumentState(sourceURL: url,
                                                  workingURL: workingURL,
                                                  document: loadedDocument,
                                                  pages: loadedPages)
        self.installOpenCandidate(newDocument, operation: operation, workingURL: workingURL)
      }
    }
  }

  func installOpenCandidate(
    _ candidate: InkSignPdfDocumentState,
    operation: InkSignPdfDocumentCoordinator.OperationToken,
    workingURL: URL
  ) {
    guard var pending = pendingOpen,
          pending.operation.id == operation.id,
          pending.phase == .preparing,
          documentCoordinator.isCurrent(operation),
          !disposed else {
      documentCoordinator.discardArtifact(workingURL)
      return
    }

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
    overlayProvider.reset()
    guard documentCoordinator.publish(candidate, operation: operation) else {
      documentCoordinator.discardArtifact(workingURL)
      failOpenAttempt(error: LoadError.pdfLoadFailed, pending: pending)
      return
    }
    documentCoordinator.claimArtifact(workingURL)
    documentID = UUID().uuidString
    overlayProvider.install(document: candidate.document, generation: operation.generation)
    documentView.document = candidate.document
    guard documentView.document === candidate.document else {
      failOpenAttempt(error: LoadError.pdfLoadFailed)
      return
    }
    interaction.viewport.navigate(to: candidate.pages[0].page)
    configureDoubleTapGestureRecognition()
    pending.phase = .awaitingReadiness
    pendingOpen = pending
    _ = completeOpenIfReady()
  }

  func finishLoad(operation: InkSignPdfDocumentCoordinator.OperationToken,
                  error: LoadError) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.disposed,
            self.documentCoordinator.isCurrent(operation),
            let pending = self.pendingOpen,
            pending.operation.id == operation.id,
            pending.phase == .preparing else { return }
      self.failOpenAttempt(error: error, pending: pending)
    }
  }

  func failOpenAttempt(
    error: Error,
    pending failed: PendingOpen? = nil
  ) {
    guard var pending = pendingOpen,
          pending.phase != .clearing,
          documentCoordinator.isCurrent(pending.operation),
          (failed.map { $0.operation.id == pending.operation.id } ?? true) else { return }
    pending.phase = .clearing
    pendingOpen = pending
    interaction.finishInteraction()
    interaction.cancelPresentation()
    pageNavigationRequestID &+= 1

    interaction.setBaseMode(ink: false, enabled: false, finish: false)
    textInteractionOverlay.clearPlacementRules()
    documentView.document = nil
    overlayProvider.reset()
    documentCoordinator.settle(pending.operation, succeeded: false)
    documentCoordinator.clearDocument()
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
    guard let state = documentCoordinator.document else { throw ViewportError.notReady }
    return InkSignPdfNativePageInfo(pageIndex: state.activePageIndex,
                                    pageCount: state.pages.count,
                                    geometry: state.activePage.geometry)
  }

  func toPublicPageInfo(_ info: InkSignPdfNativePageInfo) -> PageInfo {
    let displaySize = info.geometry.displaySize
    return PageInfo(pageIndex: Double(info.pageIndex),
                       pageCount: Double(info.pageCount),
                       width: Double(displaySize.width),
                       height: Double(displaySize.height))
  }

  /// Changes the coordinator-owned active page while keeping one PDF overlay
  /// canvas. Overlay callbacks complete the presentation handoff for the
  /// switch request that installed the target page.

}
