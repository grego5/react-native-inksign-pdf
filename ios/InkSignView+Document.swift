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
    let requestGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard let self,
            !self.disposed,
            self.generation == requestGeneration,
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
    cancelViewportAnimation()
    pendingOpen?.promise.reject(withError: LoadError.cancelled)
    pendingOpen = nil
    publicationLock.lock()
    generation &+= 1
    viewportRequestID &+= 1
    pageNavigationRequestID &+= 1
    let token = generation
    publicationLock.unlock()
    pendingOpen = PendingOpen(token: token,
                              promise: promise,
                              zoom: zoom,
                              focus: focus,
                              fitToPage: fitToPage)
    textInteractionOverlay.finishForLifecycle()
    cancelActiveStroke(clearLive: false)
    documentState = nil
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

    let requestedFallbackFont = fallbackFont

    guard !path.isEmpty else {
      pendingOpen = nil
      promise.reject(withError: LoadError.invalidSourcePath)
      return
    }

    let url = URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    loadQueue.async { [weak self] in
      guard let self else { return }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
        self.finishLoad(token: token, promise: promise, error: .invalidSourcePath); return
      }
      guard let sourceData = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
        self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
      }
      guard let loaded = PDFDocument(data: sourceData) else {
        self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
      }
      guard loaded.pageCount > 0 else {
        self.finishLoad(token: token, promise: promise, error: .unsupportedPdf); return
      }
      let pdfiumSession: InkSignPdfPdfiumSession
      do {
        pdfiumSession = try InkSignPdfPdfiumSession(
          data: sourceData,
          fallbackFontPath: requestedFallbackFont?.path,
          collectionIndex: requestedFallbackFont?.collectionIndex ?? 0)
      } catch {
        let nativeError = error as NSError
        let loadError: LoadError = nativeError.domain == InkSignPdfPdfiumErrorDomain &&
          nativeError.code == InkSignPdfPdfiumInvalidFallbackFontErrorCode
          ? .invalidFallbackFont(nativeError.localizedDescription)
          : .pdfLoadFailed
        self.finishLoad(token: token, promise: promise, error: loadError); return
      }
      guard pdfiumSession.pageCount == loaded.pageCount else {
        pdfiumSession.close()
        self.finishLoad(token: token, promise: promise, error: .unsupportedPdf); return
      }
      var loadedPages: [InkSignPdfPageState] = []
      for index in 0..<loaded.pageCount {
        guard let loadedPage = loaded.page(at: index) else {
          pdfiumSession.close()
          self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
        }
        var pdfiumSize = CGSize.zero
        do {
          try pdfiumSession.pageSize(for: UInt(index), into: &pdfiumSize)
        } catch {
          pdfiumSession.close()
          self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
        }
        let bounds = loadedPage.bounds(for: .mediaBox)
        let rotation = loadedPage.rotation
        let geometry = PageGeometry(mediaBox: bounds, rotation: rotation)
        guard pdfiumSize.width.isFinite, pdfiumSize.height.isFinite,
              geometry.isValid else {
          pdfiumSession.close()
          self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
        }
        loadedPages.append(InkSignPdfPageState(index: index,
                                                page: loadedPage,
                                                geometry: geometry))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.disposed, self.generation == token,
              self.pendingOpen?.token == token else { return }
        self.documentState = InkSignPdfDocumentState(sourceURL: url,
                                                      document: loaded,
                                                      pdfiumSession: pdfiumSession,
                                                      pages: loadedPages)
        self.pageSwitchRequestID &+= 1
        self.pendingPageSwitchID = nil
        self.documentView.installPage(
          index: 0,
          page: loadedPages[0].page,
          geometry: loadedPages[0].geometry,
          session: pdfiumSession,
          generation: token)
        self.overlayDidDisplay(self.canvasView, for: loadedPages[0].page)
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
      guard let self, !self.disposed, self.generation == token,
            self.pendingOpen?.token == token else { return }
      self.pendingOpen = nil
      promise.reject(withError: error)
    }
  }

  func setInteractionMode(editing: Bool, interactionsEnabled: Bool = true) {
    let editing = editing && documentState != nil
    textInteractionOverlay.finishForLifecycle()
    if editMode && !editing { cancelActiveStroke() }
    editMode = editing
    pageTurnLifecycle.modeChanged(editing: editing)
    let enabled = interactionsEnabled && documentState != nil && !disposed
    edgeNavigationGestureRecognizer.isEnabled = !editing && enabled
    canvasView.isHidden = documentState == nil
    canvasView.isUserInteractionEnabled = enabled
    canvasView.drawingGestureRecognizer.isEnabled = editing && enabled
    documentView.gestureRecognizers?.forEach { $0.isEnabled = !editing && enabled }
    emitChange()
  }

  func currentPageInfo() throws -> InkSignPdfNativePageInfo {
    guard let state = documentState else { throw ViewportError.notReady }
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
