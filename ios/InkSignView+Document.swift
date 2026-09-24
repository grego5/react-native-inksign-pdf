import Foundation
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
        let viewport = try Self.parseOpenViewport(options)
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
      pageTurnLifecycle.cancelUncommittedTurn()
      return
    }
    pageTurnLifecycle.cancelUncommittedTurn()
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
    let request = try Self.parseViewport(viewport)
    cancelPendingPageSwitch()
    pageTurnLifecycle.cancelUncommittedTurn()
    try requireViewportReady(request: request)
    viewportRequestID &+= 1
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
      pendingOpen = nil
      if let active = pending.operation {
        documentCoordinator.settle(active, succeeded: false)
      }
      restoreDocumentAfterOpenFailure(pending: pending)
      pending.promise.reject(withError: LoadError.cancelled)
    }
    guard let operation = documentCoordinator.admit(.open) else {
      promise.reject(withError: LoadError.operationInProgress)
      return
    }
    pageInputCoordinator.cancelPending()
    cancelViewportAnimation()
    let token = operation.generation
    let previousViewport = try? currentViewportSnapshot()
    let previousEditing = editMode
    viewportRequestID &+= 1
    pageNavigationRequestID &+= 1
    pendingOpen = PendingOpen(token: token,
                              operation: operation,
                              promise: promise,
                              zoom: zoom,
                              focus: focus,
                              fitToPage: fitToPage,
                              previousViewport: previousViewport.map {
                                ViewportTarget(zoom: CGFloat($0.zoom),
                                               focus: CGPoint(x: $0.x, y: $0.y))
                              },
                              previousEditing: previousEditing)
    textInteractionOverlay.finishForLifecycle()
    cancelActiveStroke(clearLive: false)
    setInteractionMode(editing: false, interactionsEnabled: false)
    attachedOverlayPage = nil
    textInteractionOverlay.syncContent()
    pageTurnLifecycle.cancelUncommittedTurn()
    cancelPendingPageSwitch()
    pageSwitchRequestID &+= 1
    pendingPageSwitchID = nil
    invalidateOverlayTransformCache()
    canvasView.isInstallingDrawing = true
    canvasView.drawing = PKDrawing()
    canvasView.isInstallingDrawing = false
    documentView.removePage()
    emitChange(force: true)

    guard !path.isEmpty else {
      let failed = pendingOpen
      pendingOpen = nil
      documentCoordinator.settle(operation, succeeded: false)
      restoreDocumentAfterOpenFailure(pending: failed)
      promise.reject(withError: LoadError.invalidSourcePath)
      return
    }

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
        self.finishLoad(token: token, promise: promise, error: .invalidSourcePath); return
      }
      guard let sourceData = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
        self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
      }
      do {
        let allocated = try self.artifactPolicy.allocateWorkingSource()
        guard coordinator.registerPendingArtifact(allocated, for: operation) else {
          self.artifactPolicy.deleteExact(allocated)
          self.finishLoad(token: token, promise: promise, error: .cancelled)
          return
        }
        workingURL = allocated
        try sourceData.write(to: allocated, options: .atomic)
      } catch {
        self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
      }
      guard let workingURL else {
        self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
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
        self.finishLoad(token: token, promise: promise, error: loadError); return
      } catch {
        self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
      }
      let loadedDocument = loadedCandidate.document
      let loadedPages = loadedCandidate.pages
      ownsWorkingURL = true
      DispatchQueue.main.async { [weak self, coordinator] in
        guard let self, !self.disposed, self.documentCoordinator.generation == token,
              self.pendingOpen?.token == token else {
          coordinator.discardArtifact(workingURL)
          return
        }
        let newDocument = InkSignPdfDocumentState(sourceURL: url,
                                                  workingURL: workingURL,
                                                  document: loadedDocument,
                                                  pages: loadedPages)
        guard self.documentCoordinator.publish(newDocument, operation: operation) else {
          coordinator.discardArtifact(workingURL)
          self.documentCoordinator.settle(operation, succeeded: false)
          return
        }
        coordinator.claimArtifact(workingURL)
        self.pageSwitchRequestID &+= 1
        self.pendingPageSwitchID = nil
        self.documentView.installPage(
          index: 0,
          pageID: newDocument.pages[0].id,
          geometry: newDocument.pages[0].geometry,
          page: newDocument.pages[0].page,
          document: newDocument.document,
          generation: token)
        self.overlayDidDisplay(self.canvasView, for: loadedPages[0].id)
        self.configureDoubleTapGestureRecognition()
      }
    }
  }

  func finishLoad(
    token: UInt64,
    promise: Promise<PageInfo>,
    error: LoadError
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.disposed, self.documentCoordinator.generation == token,
            self.pendingOpen?.token == token else { return }
      let failed = self.pendingOpen
      if let operation = failed?.operation {
        self.documentCoordinator.settle(operation, succeeded: false)
      }
      self.pendingOpen = nil
      self.restoreDocumentAfterOpenFailure(pending: failed)
      promise.reject(withError: error)
    }
  }

  func setInteractionMode(editing: Bool, interactionsEnabled: Bool = true) {
    let editing = editing && documentCoordinator.document != nil
    textInteractionOverlay.finishForLifecycle()
    if editMode && !editing { cancelActiveStroke() }
    editMode = editing
    pageTurnLifecycle.modeChanged(editing: editing)
    let enabled = interactionsEnabled && documentCoordinator.document != nil && !disposed
    edgeNavigationGestureRecognizer.isEnabled = !editing && enabled
    canvasView.isHidden = documentCoordinator.document == nil
    canvasView.isUserInteractionEnabled = enabled
    canvasView.drawingGestureRecognizer.isEnabled = editing && enabled
    documentView.gestureRecognizers?.forEach { $0.isEnabled = !editing && enabled }
    emitChange()
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
