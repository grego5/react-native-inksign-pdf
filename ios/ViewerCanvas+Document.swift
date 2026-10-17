import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules
import QuartzCore

extension ViewerCanvas {
  func enqueueViewerCommand<T>(modeSession: InkSignPdfModeSessionToken? = nil,
                               _ action: @escaping () throws -> Promise<T>) -> Promise<T> {
    let result = InkSignPdfOperationPromise<T>()
    performOnMain {
      guard !self.disposed, modeSession.map(self.interaction.sessionIsCurrent) ?? true else {
        result.reject(OperationError.cancelled); return
      }
      let id = UUID()
      let entry = ViewerCommand(id: id, modeSession: modeSession, start: { [weak self] in
        guard let self else { result.reject(OperationError.cancelled); return }
        do {
          if let modeSession { try self.interaction.requireSession(modeSession) }
          let operation = try action()
          operation.then { value in
            self.performOnMain {
              if let modeSession, !self.interaction.sessionIsCurrent(modeSession) { result.reject(OperationError.cancelled) }
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
      }, cancel: { result.reject(OperationError.cancelled) })
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

  func cancelViewerCommands() {
    interaction.cancelCoordinates()
    let retired = commandQueue
    commandQueue.removeAll()
    let running = runningCommand
    runningCommand = nil
    retired.forEach { $0.cancel() }
    running?.cancel()
  }

  func clearPresentation() {
    let retiring = viewerDocument
    defer { withExtendedLifetime(retiring) {} }
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
    documentView.layoutDocumentView()
    documentView.layoutIfNeeded()
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

  func selectPage(index: Double) throws {
    try performOnMainSync { try self.selectPage(index: index, session: nil) }
  }

  func selectPage(index: Double, session: InkSignPdfModeSessionToken?) throws {
    guard !disposed else { throw ViewportError.cancelled }
    if let session { try interaction.requireSession(session) }
    let current = try currentPageInfo()
    guard index.isFinite, index >= 0, index.rounded(.towardZero) == index,
          index < Double(current.pageCount) else { throw MutablePageError.invalidPageIndex }
    try navigatePage(to: Int(index), current: current, session: session)
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
    try navigatePage(to: target, current: current, session: nil)
  }

  private func navigatePage(to target: Int, current: InkSignPdfNativePageInfo,
                            session: InkSignPdfModeSessionToken?) throws {
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
            self.attachedCore?.coordinator.generation == requestGeneration,
            self.pageNavigationRequestID == requestID else { return }
      if let session, !self.interaction.sessionIsCurrent(session) { return }
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

  func documentStateSnapshot() -> DocumentState {
    return DocumentState(documentId: documentID.map { .second($0) } ?? .first(.null),
      pageCount: Double(attachedCore?.coordinator.document?.pages.count ?? 0),
      isDirty: attachedCore?.coordinator.isDirty ?? false)
  }

  func setMode(mode: InputMode, options: TextModeOptions?) throws -> any HybridModeSessionSpec {
    try performOnMainSync {
      _ = try attachedCore?.fonts.resolve(options?.font)
      let token = try interaction.beginSession(mode, options: options)
      return HybridModeSession(owner: self, token: token)
    }
  }

  func configureCanvasInteraction(_ canvas: InkCanvasView) {
    let enabled = interaction.inputEnabled
    canvas.isHidden = viewerDocument == nil
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
    guard !disposed else { return }
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
