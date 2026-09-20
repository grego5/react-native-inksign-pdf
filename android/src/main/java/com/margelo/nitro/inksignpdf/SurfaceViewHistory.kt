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
      mutation.content.mapNotNull { entry ->
        (entry as? PageContent.Ink)?.outline
      },
    )
    is InkHistoryMutation.Cleared -> inkRenderer.clearCompleted()
  }
  rebuildCommittedTextLayer()
  notifyStateChange()
  invalidate()
  onTextContentChanged?.invoke()
  pageNavigationController.reconcilePreviews()
}

internal fun SurfaceView.activeHistory(): InkHistory {
  val state = checkNotNull(documentState)
  return state.page(state.activePageIndex).history
}

internal fun SurfaceView.rebuildCommittedTextLayer() {
  val state = documentState
  if (state == null) {
    committedTextLayer = TextRenderLayer.empty()
    return
  }
  committedTextLayer = TextRenderLayer.from(
    state.page(state.activePageIndex).history.contentSnapshot().mapNotNull { content ->
      (content as? PageContent.Text)?.annotation
    },
  )
}

internal fun SurfaceView.validateTextMutation(generation: Long, pageIndex: Int) {
  requireOnUiThread()
  if (disposed) {
    throw PdfSessionException("operation_cancelled", "PDF view was disposed")
  }
  val state = documentState
  if (state == null || state.generation != generation || state.activePageIndex != pageIndex) {
    throw PdfSessionException(
      "operation_cancelled",
      "Text editing was superseded by a document or page change",
    )
  }
}

internal fun SurfaceView.reportedState(): InkState {
  val state = documentState ?: return InkState(false, false, false)
  val active = state.page(state.activePageIndex).history.state()
  return InkState(
    canUndo = active.canUndo,
    canRedo = active.canRedo,
    isDirty = state.pages.any { it.history.state().isDirty },
  )
}

internal fun SurfaceView.resetDocumentHistories() {
  documentState?.pages?.forEach { it.history.reset() }
}
