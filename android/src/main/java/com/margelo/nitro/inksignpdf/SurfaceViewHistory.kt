package com.margelo.nitro.inksignpdf

internal fun SurfaceView.notifyStateChange() {
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

internal fun SurfaceView.reconcileStateAfterOpenAbort() {
  requireOnUiThread()
  val state = reportedState()
  lastReportedState = state
  if (stateNotificationsSuspended > 0) {
    stateNotificationPending = true
  } else {
    onStateChange?.invoke(state)
  }
}

internal fun SurfaceView.withStateTransaction(action: () -> Unit) {
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

internal fun SurfaceView.presentHistoryMutation(mutation: InkHistoryMutation) {
  when (mutation) {
    InkHistoryMutation.NoOp -> return
    is InkHistoryMutation.Appended -> inkRenderer.addCompletedOutline(mutation.outline)
    is InkHistoryMutation.Removed -> inkRenderer.removeLastCompleted(mutation.outline)
    is InkHistoryMutation.Replaced -> inkRenderer.setCompletedHistory(
      mutation.content.mapNotNull { it.inkOutlineOrNull() },
    )
    is InkHistoryMutation.Cleared -> inkRenderer.clearCompleted()
  }
  rebuildCommittedTextLayer()
  notifyStateChange()
  invalidate()
  onTextContentChanged?.invoke()
  pageNavigationController.reconcilePreviews()
}

internal fun SurfaceView.rebuildCommittedTextLayer() {
  val state = documentCoordinator.takeIf { it.hasDocument }
  if (state == null) {
    committedTextLayer = TextRenderLayer.empty()
    return
  }
  committedTextLayer = TextRenderLayer.from(
    state.pageSnapshot(state.activePageIndex).content.mapNotNull { it.textAnnotationOrNull() },
  )
}

internal fun SurfaceView.validateTextMutation(generation: Long, pageIndex: Int) {
  requireOnUiThread()
  if (disposed) {
    throw PdfSessionException("operation_cancelled", "PDF view was disposed")
  }
  val state = documentCoordinator.takeIf { it.hasDocument }
  if (state == null || state.generation != generation || state.activePageIndex != pageIndex) {
    throw PdfSessionException(
      "operation_cancelled",
      "Text editing was superseded by a document or page change",
    )
  }
}

internal fun SurfaceView.reportedState(): InkState {
  val state = documentCoordinator.takeIf { it.hasDocument } ?: return InkState(false, false, false)
  val active = state.activeHistoryState()
  return InkState(
    canUndo = active.canUndo,
    canRedo = active.canRedo,
    isDirty = state.isDirty(),
  )
}

internal fun SurfaceView.resetDocumentHistories() {
  if (documentCoordinator.hasDocument) documentCoordinator.resetHistories()
}
