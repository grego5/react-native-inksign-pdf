import Foundation
import PencilKit

extension InkSignView {
  func undo() throws {
    try performOnMainSync {
      let pageID = self.viewerDocument?.activePage.id
      let generation = self.documentCoordinator.generation
      guard self.interaction.finishInteraction(), self.documentCoordinator.generation == generation,
            let page = self.viewerDocument?.activePage, page.id == pageID else { return }
      try self.documentCore.undo(InkSignPdfCorePageContext(generation: generation, pageID: page.id))
    }
  }

  func redo() throws {
    try performOnMainSync {
      let pageID = self.viewerDocument?.activePage.id
      let generation = self.documentCoordinator.generation
      guard self.interaction.finishInteraction(), self.documentCoordinator.generation == generation,
            let page = self.viewerDocument?.activePage, page.id == pageID else { return }
      try self.documentCore.redo(InkSignPdfCorePageContext(generation: generation, pageID: page.id))
    }
  }

  func clear() throws {
    try performOnMainSync {
      let pageID = self.viewerDocument?.activePage.id
      let generation = self.documentCoordinator.generation
      guard self.interaction.finishInteraction(), self.documentCoordinator.generation == generation,
            let page = self.viewerDocument?.activePage, page.id == pageID else { return }
      try self.documentCore.clear(InkSignPdfCorePageContext(generation: generation, pageID: page.id))
    }
  }

  func clearInk() throws {
    try performOnMainSync {
      self.cancelActiveStroke()
      guard let page = self.viewerDocument?.activePage else { return }
      try self.documentCore.clear(InkSignPdfCorePageContext(generation: self.documentCoordinator.generation,
        pageID: page.id), inkOnly: true)
    }
  }

  func documentCoreDidChange(_ change: InkSignDocumentCore.Change) {
    guard !disposed else { return }
    switch change {
    case .page(let id):
      guard let presented = viewerDocument, documentCoordinator.document === presented.core else { return }
      if presented.activePageID == id {
        if !hasDrawingTransaction { installCommittedDrawing() }
        textInteractionOverlay.syncContent()
      }
      emitChange()
    case .document, .structure:
      // Presentation installation owns page-ready events. The mutation is already
      // committed and observers cannot hold the core queue waiting for that work.
      break
    }
  }

  func emitChange(force: Bool = false) {
    guard !disposed else { return }
    guard !suppressesOpenPresentationCallbacks else { return }
    guard !interaction.deferStateChange(force: force) else { return }
    emitPageState()
    let document = documentStateSnapshot()
    let mode = interactionMode()
    let pageIndex = viewerDocument?.activePageIndex
    let tuple = (Int(document.pageCount), document.isDirty, mode.stringValue, documentID, loadError, pageIndex)
    guard force || lastChange == nil || lastChange!.0 != tuple.0 ||
            lastChange!.1 != tuple.1 || lastChange!.2 != tuple.2 || lastChange!.3 != tuple.3 || lastChange!.4 != tuple.4 || lastChange!.5 != tuple.5 else { return }
    lastChange = tuple
    onStateChange?(ViewerState(mode: mode, error: loadError.map { .second($0) } ?? .first(.null),
      pageIndex: pageIndex.map { .second(Double($0)) } ?? .first(.null),
      documentId: document.documentId, pageCount: document.pageCount, isDirty: document.isDirty))
  }
}
