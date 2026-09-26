import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules
import QuartzCore

extension InkSignView {
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
    let promise = Promise<PageInfo>()
    performOnMain {
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
    cancelPendingPageSwitch()
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
      return try self.currentViewportSnapshot()
    }
  }

  func enterEditMode(viewport: ViewportOptions?) throws {
    try performOnMainSync { try self.transition(toEditing: true, viewport: viewport) }
  }

  func enterViewMode(viewport: ViewportOptions?) throws {
    try performOnMainSync { try self.transition(toEditing: false, viewport: viewport) }
  }

  private func transition(toEditing: Bool, viewport: ViewportOptions?) throws {
    guard !disposed else { throw ViewportError.cancelled }
    let request = Self.parseViewport(viewport)
    cancelPendingPageSwitch()
    try requireViewportReady(request: request)
    try applyModeTransition(toEditing: toEditing, request: request)
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
    if let pending = pendingOpen {
      switch pending.phase {
      case .preparing:
        pendingOpen = nil
        documentCoordinator.settle(pending.operation, succeeded: false)
        pending.promise.reject(withError: LoadError.cancelled)
      case .installing, .awaitingReadiness:
        queueOpen(path, zoom: zoom, focus: focus, fitToPage: fitToPage, promise: promise)
        failOpenAttempt(error: LoadError.cancelled, pending: pending)
        return
      case .clearing:
        queueOpen(path, zoom: zoom, focus: focus, fitToPage: fitToPage, promise: promise)
        return
      }
    }
    guard let operation = documentCoordinator.admit(.open) else {
      promise.reject(withError: LoadError.operationInProgress)
      return
    }
    pendingOpen = PendingOpen(operation: operation,
                              promise: promise,
                              zoom: zoom,
                              focus: focus,
                              fitToPage: fitToPage)

    let url = URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
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
        try sourceData.write(to: allocated, options: .atomic)
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
    textInteractionOverlay.finishForLifecycle()
    pageInputCoordinator.cancelPending()
    cancelActiveStroke(clearLive: false)
    applyInteractionMode(editing: false, interactionsEnabled: false)
    cancelPendingPageSwitch()
    pageNavigationRequestID &+= 1
    pageSwitchRequestID &+= 1
    pendingPageSwitchID = nil
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
    overlayProvider.install(document: candidate.document, generation: operation.generation)
    documentView.document = candidate.document
    guard documentView.document === candidate.document else {
      failOpenAttempt(error: LoadError.pdfLoadFailed)
      return
    }
    documentView.go(to: candidate.pages[0].page)
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

  private func queueOpen(_ path: String,
                         zoom: Double?,
                         focus: CGPoint?,
                         fitToPage: Bool,
                         promise: Promise<PageInfo>) {
    let replaced = queuedOpen
    queuedOpen = QueuedOpen(path: path,
                            zoom: zoom,
                            focus: focus,
                            fitToPage: fitToPage,
                            promise: promise)
    replaced?.promise.reject(withError: LoadError.cancelled)
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
    textInteractionOverlay.finishForLifecycle()
    cancelActiveStroke(clearLive: false)
    cancelPendingPageSwitch()
    pageNavigationRequestID &+= 1
    pageSwitchRequestID &+= 1
    applyInteractionMode(editing: false, interactionsEnabled: false)
    textInteractionOverlay.clearPlacementRules()
    documentView.document = nil
    overlayProvider.reset()
    documentCoordinator.settle(pending.operation, succeeded: false)
    documentCoordinator.clearDocument()
    attachedOverlayPage = nil
    invalidateOverlayTransformCache()
    pendingOpen = nil
    emitChange(force: true)
    pending.promise.reject(withError: error)
    guard !disposed, pendingOpen == nil else {
      let superseded = queuedOpen
      queuedOpen = nil
      superseded?.promise.reject(withError: LoadError.cancelled)
      return
    }
    startQueuedOpen()
  }

  func setInteractionMode(editing: Bool, interactionsEnabled: Bool = true) {
    let editing = editing && documentCoordinator.document != nil
    textInteractionOverlay.finishForLifecycle()
    if editMode && !editing { cancelActiveStroke() }
    applyInteractionMode(editing: editing, interactionsEnabled: interactionsEnabled)
    emitChange()
  }

  func applyInteractionMode(editing: Bool, interactionsEnabled: Bool) {
    let editing = editing && documentCoordinator.document != nil
    editMode = editing
    let enabled = interactionsEnabled && documentCoordinator.document != nil && !disposed
    viewInteractionsEnabled = enabled
    canvasView.isHidden = documentCoordinator.document == nil
    canvasView.isUserInteractionEnabled = enabled
    canvasView.drawingGestureRecognizer.isEnabled = editing && enabled
    pdfViewInteractionOwnership.update(
      pdfView: documentView,
      editing: editing,
      interactionsEnabled: enabled,
      placementRecognizer: textInteractionOverlay.placementTapRecognizer)
  }

  func updatePDFViewInteractionOwnership() {
    pdfViewInteractionOwnership.update(
      pdfView: documentView,
      editing: editMode,
      interactionsEnabled: viewInteractionsEnabled,
      placementRecognizer: textInteractionOverlay.placementTapRecognizer)
  }

  func currentPageInfo() throws -> InkSignPdfNativePageInfo {
    guard let state = documentCoordinator.document else { throw ViewportError.notReady }
    return InkSignPdfNativePageInfo(pageIndex: state.activePageIndex,
                                    pageCount: state.pages.count,
                                    geometry: state.activePage.geometry)
  }

  func toPublicPageInfo(_ info: InkSignPdfNativePageInfo) -> PageInfo {
    PageInfo(pageIndex: Double(info.pageIndex),
                       pageCount: Double(info.pageCount),
                       width: Double(info.geometry.mediaBox.width),
                       height: Double(info.geometry.mediaBox.height))
  }

  /// Changes the coordinator-owned active page while keeping one PDF overlay
  /// canvas. Overlay callbacks complete the presentation handoff for the
  /// switch request that installed the target page.

}
