package com.margelo.nitro.inksignpdf

internal fun ViewerCanvas.notifyStateChange() {
  requireOnUiThread()
  val state = reportedState()
  if (state == lastReportedState) return
  lastReportedState = state
  if (stateNotificationsSuspended > 0) {
    stateNotificationPending = true
    return
  }
  onStateChange?.invoke(state)
}

internal fun ViewerCanvas.reconcileStateAfterOpenAbort() {
  requireOnUiThread()
  val state = reportedState()
  lastReportedState = state
  if (stateNotificationsSuspended > 0) {
    stateNotificationPending = true
  } else {
    onStateChange?.invoke(state)
  }
}

internal fun ViewerCanvas.withStateTransaction(action: () -> Unit) {
  requireOnUiThread()
  stateNotificationsSuspended += 1
  stateNotificationPending = true
  try {
    action()
  } finally {
    stateNotificationsSuspended -= 1
    if (stateNotificationsSuspended == 0 && stateNotificationPending) {
      stateNotificationPending = false
      val finalState = reportedState()
      lastReportedState = finalState
      onStateChange?.invoke(finalState)
    }
  }
}

internal fun ViewerCanvas.presentContentChange(change: DocumentChange.Content) {
  requireOnUiThread()
  check(change.generation == documentState.generation)
  val mutation = change.mutation
  if (documentState.activePageId() != change.pageId) {
    notifyStateChange()
    invalidate()
    return
  }
  when (mutation) {
    InkHistoryMutation.NoOp -> return
    is InkHistoryMutation.Appended -> inkRenderer.addCompletedOutline(mutation.outline)
    is InkHistoryMutation.Removed -> inkRenderer.removeLastCompleted(mutation.outline)
    is InkHistoryMutation.Replaced -> inkRenderer.setCompletedHistory(
      mutation.content.mapNotNull { it.inkOutlineOrNull() },
    )
    is InkHistoryMutation.Cleared -> inkRenderer.clearCompleted()
  }
  val textChanged = mutation is InkHistoryMutation.Replaced || mutation is InkHistoryMutation.Cleared
  if (textChanged) rebuildCommittedTextLayer()
  notifyStateChange()
  invalidate()
  if (textChanged) onTextContentChanged?.invoke()
}

internal fun ViewerCanvas.rebuildCommittedTextLayer() {
  val state = documentState.takeIf { it.hasDocument }
  if (state == null) {
    committedTextLayer = TextRenderLayer.empty()
    return
  }
  committedTextLayer = TextRenderLayer.from(
    state.pageSnapshot(state.activePageIndex).content.mapNotNull { it.textAnnotationOrNull() },
  )
}

internal fun ViewerCanvas.reportedState(): InkState {
  val state = documentState.takeIf { it.hasDocument } ?: return InkState(false, false, false)
  val active = state.activeHistoryState()
  return InkState(
    canUndo = active.canUndo,
    canRedo = active.canRedo,
    isDirty = state.isDirty(),
  )
}
