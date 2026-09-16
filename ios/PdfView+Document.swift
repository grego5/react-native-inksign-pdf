import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules
import QuartzCore

extension PdfView {
  func performOnMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
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

  func nextPage() throws -> Promise<PageInfo> {
    navigatePage(by: 1)
  }

  func previousPage() throws -> Promise<PageInfo> {
    navigatePage(by: -1)
  }

  private func navigatePage(by delta: Int) -> Promise<PageInfo> {
    let promise = Promise<PageInfo>()
    publicationLock.lock()
    let requestGeneration = generation
    publicationLock.unlock()
    performOnMain {
      guard !self.disposed, self.generation == requestGeneration else {
        promise.reject(withError: ViewportError.cancelled)
        return
      }
      do {
        let current = try self.currentPageInfo()
        let target = Int(min(max(current.pageIndex + Double(delta), 0), current.pageCount - 1))
        if Double(target) == current.pageIndex {
          self.pageTurnLifecycle.cancelUncommittedTurn()
          promise.resolve(withResult: self.toPublicPageInfo(current))
          return
        }
        self.pageTurnLifecycle.cancelUncommittedTurn()
        try self.switchPage(to: target,
                            completion: self.programmaticPageSwitchCompletion(promise: promise))
      } catch {
        promise.reject(withError: error)
      }
    }
    return promise
  }

  func getViewport() throws -> Promise<Viewport> {
    let promise = Promise<Viewport>()
    publicationLock.lock()
    let requestGeneration = generation
    publicationLock.unlock()
    performOnMain {
      guard !self.disposed, self.generation == requestGeneration else {
        promise.reject(withError: ViewportError.cancelled)
        return
      }
      do {
        let viewport = try self.currentViewportSnapshot()
        guard !self.disposed, self.generation == requestGeneration else {
          throw ViewportError.cancelled
        }
        promise.resolve(withResult: viewport)
      } catch {
        promise.reject(withError: error)
      }
    }
    return promise
  }

  func enterEditMode(viewport: ViewportOptions?) throws -> Promise<Void> {
    transition(toEditing: true, viewport: viewport)
  }

  func enterViewMode(viewport: ViewportOptions?) throws -> Promise<Void> {
    transition(toEditing: false, viewport: viewport)
  }

  private func transition(toEditing: Bool, viewport: ViewportOptions?) -> Promise<Void> {
    let promise = Promise<Void>()
    publicationLock.lock()
    let requestGeneration = generation
    publicationLock.unlock()
    performOnMain {
      guard !self.disposed else {
        promise.reject(withError: ViewportError.cancelled)
        return
      }
      guard self.generation == requestGeneration else {
        promise.reject(withError: ViewportError.cancelled)
        return
      }
      do {
        let request = try Self.parseViewport(viewport)
        self.cancelPendingPageSwitch()
        self.pageTurnLifecycle.cancelUncommittedTurn()
        try self.requireViewportReady(request: request)
        self.publicationLock.lock()
        guard !self.disposed, self.generation == requestGeneration else {
          self.publicationLock.unlock()
          throw ViewportError.cancelled
        }
        self.viewportRequestID &+= 1
        let requestID = self.viewportRequestID
        self.publicationLock.unlock()
        guard self.viewportRequestID == requestID else {
          throw ViewportError.cancelled
        }
        try self.applyModeTransition(toEditing: toEditing, request: request)
        promise.resolve(withResult: ())
      } catch {
        promise.reject(withError: error)
      }
    }
    return promise
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
    let token = generation
    publicationLock.unlock()
    pendingOpen = PendingOpen(token: token,
                              promise: promise,
                              zoom: zoom,
                              focus: focus,
                              fitToPage: fitToPage)
    textInteractionOverlay.finishForLifecycle()
    cancelActiveStroke(clearLive: false)
    editMode = false
    canvasView.isUserInteractionEnabled = false
    canvasView.isHidden = true
    documentView.pageOverlayViewProvider = nil
    documentState = nil
    attachedOverlayPage = nil
    textInteractionOverlay.syncContent()
    pageTurnLifecycle.cancelUncommittedTurn()
    edgeNavigationGestureRecognizer.isEnabled = false
    cancelPendingPageSwitch()
    pageSwitchRequestID &+= 1
    pendingPageSwitchID = nil
    invalidateOverlayTransformCache()
    canvasView.isInstallingDrawing = true
    canvasView.drawing = PKDrawing()
    canvasView.isInstallingDrawing = false
    documentView.document = nil
    emitChange(force: true)

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
      guard let loaded = PDFDocument(url: url) else {
        self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
      }
      guard loaded.pageCount > 0 else {
        self.finishLoad(token: token, promise: promise, error: .unsupportedPdf); return
      }
      var loadedPages: [InkSignPdfPageState] = []
      for index in 0..<loaded.pageCount {
        guard let loadedPage = loaded.page(at: index) else {
          self.finishLoad(token: token, promise: promise, error: .pdfLoadFailed); return
        }
        let bounds = loadedPage.bounds(for: .mediaBox)
        let rotation = loadedPage.rotation
        let geometry = PageGeometry(mediaBox: bounds, rotation: rotation)
        guard geometry.isValid else {
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
                                                      pages: loadedPages)
        self.pageSwitchRequestID &+= 1
        self.pendingPageSwitchID = nil
        self.documentView.pageOverlayViewProvider = self.overlayProvider
        self.documentView.document = loaded
        self.configureDoubleTapGestureRecognition()
        _ = self.tryApplyPendingOpenViewport()
        _ = self.tryCompletePendingOpen()
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

  func setInteractionMode(editing: Bool) {
    let editing = editing && documentState != nil
    textInteractionOverlay.finishForLifecycle()
    if editMode && !editing { cancelActiveStroke() }
    editMode = editing
    pageTurnLifecycle.modeChanged(editing: editing)
    edgeNavigationGestureRecognizer.isEnabled = !editing && documentState != nil && !disposed
    canvasView.isHidden = documentState == nil
    canvasView.isUserInteractionEnabled = documentState != nil
    documentView.gestureRecognizers?.forEach { $0.isEnabled = !editing }
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
