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
    guard let state = documentCoordinator.document else {
      documentID = nil
      let mode = interactionMode()
      let tuple = (false, false, false, mode.stringValue, documentID, loadError)
      if force || lastChange == nil || lastChange!.0 != tuple.0 ||
          lastChange!.1 != tuple.1 || lastChange!.2 != tuple.2 || lastChange!.3 != tuple.3 || lastChange!.4 != tuple.4 || lastChange!.5 != tuple.5 {
        lastChange = tuple
        onStateChange?(ViewerState(documentId: documentID.map { .second($0) } ?? .first(.null), canUndo: false, canRedo: false, isDirty: false,
                                        mode: mode, error: loadError.map { .second($0) } ?? .first(.null)))
      }
      return
    }
    if documentID == nil { documentID = UUID().uuidString }
    let page = state.activePage
    let pageState = page.history.state
    let value = (canUndo: pageState.canUndo, canRedo: pageState.canRedo,
                 isDirty: documentCoordinator.isDirty)
    let mode = interactionMode()
    let tuple = (value.canUndo, value.canRedo, value.isDirty, mode.stringValue, documentID, loadError)
    guard force || lastChange == nil || lastChange!.0 != tuple.0 ||
            lastChange!.1 != tuple.1 || lastChange!.2 != tuple.2 || lastChange!.3 != tuple.3 || lastChange!.4 != tuple.4 || lastChange!.5 != tuple.5 else { return }
    lastChange = tuple
    onStateChange?(ViewerState(documentId: documentID.map { .second($0) } ?? .first(.null), canUndo: value.canUndo,
                                    canRedo: value.canRedo,
                                    isDirty: value.isDirty,
                                    mode: mode, error: loadError.map { .second($0) } ?? .first(.null)))
  }
}
