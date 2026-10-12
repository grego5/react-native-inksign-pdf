import Foundation
import PencilKit

extension InkSignView {
  func undo() throws {
    try performOnMainSync {
      let pageID = self.documentCoordinator.document?.activePage.id
      let generation = self.documentCoordinator.generation
      guard self.interaction.finishInteraction(), self.documentCoordinator.generation == generation,
            let page = self.documentCoordinator.document?.activePage, page.id == pageID else { return }
      guard page.history.undo() else { return }
      self.documentCoordinator.synchronizeTextPlacement(on: page)
      self.installCommittedDrawing()
      self.textInteractionOverlay.syncContent()
      self.emitChange()
    }
  }

  func redo() throws {
    try performOnMainSync {
      let pageID = self.documentCoordinator.document?.activePage.id
      let generation = self.documentCoordinator.generation
      guard self.interaction.finishInteraction(), self.documentCoordinator.generation == generation,
            let page = self.documentCoordinator.document?.activePage, page.id == pageID else { return }
      guard page.history.redo() else { return }
      self.documentCoordinator.synchronizeTextPlacement(on: page)
      self.installCommittedDrawing()
      self.textInteractionOverlay.syncContent()
      self.emitChange()
    }
  }

  func clear() throws {
    try performOnMainSync {
      let pageID = self.documentCoordinator.document?.activePage.id
      let generation = self.documentCoordinator.generation
      guard self.interaction.finishInteraction(), self.documentCoordinator.generation == generation,
            let page = self.documentCoordinator.document?.activePage, page.id == pageID else { return }
      page.history.clear()
      self.installCommittedDrawing()
      self.textInteractionOverlay.syncContent()
      self.emitChange()
    }
  }

  func clearInk() throws {
    try performOnMainSync {
      self.cancelActiveStroke()
      guard let page = self.documentCoordinator.document?.activePage else { return }
      let before = page.history.content
      guard !before.drawing.strokes.isEmpty else { return }
      guard page.history.record(type: .clear, before: before,
                                after: before.replacingDrawing(PKDrawing())) else { return }
      self.installCommittedDrawing()
      self.emitChange()
    }
  }

  func emitChange(force: Bool = false) {
    guard !disposed else { return }
    guard !suppressesOpenPresentationCallbacks else { return }
    guard !interaction.deferStateChange(force: force) else { return }
    emitPageState()
    let document = documentStateSnapshot()
    let mode = interactionMode()
    let pageIndex = documentCoordinator.document?.activePageIndex
    let tuple = (Int(document.pageCount), document.isDirty, mode.stringValue, documentID, loadError, pageIndex)
    guard force || lastChange == nil || lastChange!.0 != tuple.0 ||
            lastChange!.1 != tuple.1 || lastChange!.2 != tuple.2 || lastChange!.3 != tuple.3 || lastChange!.4 != tuple.4 || lastChange!.5 != tuple.5 else { return }
    lastChange = tuple
    onStateChange?(ViewerState(mode: mode, error: loadError.map { .second($0) } ?? .first(.null),
      pageIndex: pageIndex.map { .second(Double($0)) } ?? .first(.null),
      documentId: document.documentId, pageCount: document.pageCount, isDirty: document.isDirty))
  }
}
