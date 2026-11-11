import Foundation
import PencilKit

extension ViewerCanvas {
  func documentCoreDidChange(_ change: DocumentCore.Change) {
    guard !disposed else { return }
    switch change {
    case .loadFailed(let error):
      loadError = error.localizedDescription
      emitChange(force: true)
    case .editEnded(let edit): textInteractionOverlay.endEditorTransaction(edit)
    case .inkCleared(let id):
      if viewerDocument?.activePageID == id { cancelActiveStroke(clearLive: true) }
    case .historyResetStarted:
      textInteractionOverlay.finishEditing(keepingSelection: true)
      cancelActiveStroke(clearLive: true)
    case .historyReset: emitChange()
    case .willClose:
      if document != nil { releaseAttachment() }
    case .structuralWriteStarted:
      if document != nil {
        cancelActiveStroke(clearLive: true)
        interaction.suspendStructural()
      }
    case .page(let id):
      guard let presented = viewerDocument, documentCoordinator.document === presented.core else { return }
      if presented.activePageID == id {
        if !hasDrawingTransaction { installCommittedDrawing() }
        textInteractionOverlay.syncContent()
      }
      emitChange()
    case .document, .structure:
      if document != nil {
        guard let state = documentCoordinator.document else {
          clearPresentation()
          emitChange(force: true)
          return
        }
        let oldID = viewerDocument?.activePageID
        let oldIndex = viewerDocument?.activePageIndex ?? 0
        let selected = oldID.flatMap { state.index(of: $0) == nil ? nil : $0 }
          ?? state.pages[min(oldIndex, state.pages.count - 1)].id
        let selectedPage = state.pages[state.index(of: selected)!]
        let fitPage = oldID != selected || viewerDocument?.activePDFPage.rotation != selectedPage.geometry.rotation
        installStructuralPresentation(state,
          viewport: try? interaction.viewport.currentViewportSnapshot(), selectedPageID: selected, fitPage: fitPage,
          completion: structuralPresentationCompletion())
        return
      }
      // Presentation installation owns page-ready events. The mutation is already
      // committed and observers cannot hold the core queue waiting for that work.
      break
    }
  }

  func emitChange(force: Bool = false) {
    guard !disposed else { return }
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
