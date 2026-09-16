import PencilKit

extension PdfView {
  func undo() {
    performOnMain {
      self.cancelActiveStroke()
      self.textInteractionOverlay.finishForLifecycle()
      guard let page = self.documentState?.activePage else { return }
      guard page.history.undo() else { return }
      self.installCommittedDrawing()
      self.textInteractionOverlay.syncContent()
      self.emitChange()
    }
  }

  func redo() {
    performOnMain {
      self.cancelActiveStroke()
      self.textInteractionOverlay.finishForLifecycle()
      guard let page = self.documentState?.activePage else { return }
      guard page.history.redo() else { return }
      self.installCommittedDrawing()
      self.textInteractionOverlay.syncContent()
      self.emitChange()
    }
  }

  func clear() {
    performOnMain {
      self.cancelActiveStroke()
      self.textInteractionOverlay.finishForLifecycle()
      guard let page = self.documentState?.activePage else { return }
      page.history.clear()
      self.installCommittedDrawing()
      self.textInteractionOverlay.syncContent()
      self.emitChange()
    }
  }

  func emitChange(force: Bool = false) {
    guard let state = documentState else {
      let mode = textInteractionOverlay.interactionMode()
      let tuple = (false, false, false, mode.stringValue)
      if force || lastChange == nil || lastChange!.0 != tuple.0 ||
          lastChange!.1 != tuple.1 || lastChange!.2 != tuple.2 || lastChange!.3 != tuple.3 {
        lastChange = tuple
        onStateChange?(StateChangeEvent(canUndo: false, canRedo: false, isDirty: false,
                                        mode: textInteractionOverlay.interactionMode()))
      }
      return
    }
    let page = state.activePage
    let pageState = page.history.state
    let value = (canUndo: pageState.canUndo, canRedo: pageState.canRedo,
                 isDirty: state.pages.contains { !$0.history.content.isEmpty })
    let mode = textInteractionOverlay.interactionMode()
    let tuple = (value.canUndo, value.canRedo, value.isDirty, mode.stringValue)
    guard force || lastChange == nil || lastChange!.0 != tuple.0 ||
            lastChange!.1 != tuple.1 || lastChange!.2 != tuple.2 || lastChange!.3 != tuple.3 else { return }
    lastChange = tuple
    onStateChange?(StateChangeEvent(canUndo: value.canUndo,
                                    canRedo: value.canRedo,
                                    isDirty: value.isDirty,
                                    mode: textInteractionOverlay.interactionMode()))
  }
}
