package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.HapticFeedbackConstants
import kotlin.math.max
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

internal data class PreparedDocumentPresentation(
  val viewport: PageViewport,
  val pageInfo: PdfPageInfo,
)

/**
 * The single Android presentation surface for PDF rendering, navigation, and
 * edit-mode ink input.
 *
 * PDF work stays on [sessionWorker]. The UI thread owns the document controller,
 * active pointer, and ink renderer. The
 * engine remains the live stroke model; [InkHistory] owns ordered committed
 * page content, [InkRenderer] owns completed RenderNode batches,
 * and AndroidX owns active front-buffer presentation.
 */
internal class SurfaceView(
  context: Context,
  internal val inkEngine: InkEngine,
  internal val traceRecorder: StrokeTraceRecorder = createStrokeTraceRecorder(),
  predictor: InputPredictor? = null,
  internal val lowLatencyInk: LowLatencyInkHost =
    UnavailableLowLatencyInkHost,
  private val pageNavigationPreviewScheduler: PageNavigationPreviewScheduler? = null,
  private val pageNavigationSettlementDriver: PageNavigationSettlementDriver? = null,
  internal val documentCoordinator: MutableDocumentCoordinator,
) : android.view.View(context) {
  internal companion object {
    internal const val CANCELLATION_NONE = 0
    internal const val CANCELLATION_INPUT = 1
    internal const val CANCELLATION_LIFECYCLE = 2
    internal const val PREDICTION_SUPPRESSION_NONE = 0
    internal const val noPointer = -1
    internal const val millisToSeconds = 0.001
  }

  internal data class PredictionReplacementEffect(
    val previousBounds: InkBounds?,
    val currentBounds: InkBounds?,
  )

  private val backgroundColor = Color.rgb(0xD0, 0xD0, 0xD0)
  private val pagePreviewPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    isFilterBitmap = true
  }
  private val pagePreviewPagePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
  }
  private val pagePreviewInkPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
  }
  private val pagePreviewMatrix = Matrix()
  internal val inkRenderer = InkRenderer()
  internal val sessionWorker: PdfSessionWorker = documentCoordinator.sessionWorker
  private var pageSwitchRequestId = 0L
  internal val currentPageSwitchId: Long get() = pageSwitchRequestId
  internal val documentController = InkDocumentController(
    context = context,
    sessionWorker = sessionWorker,
    requestInvalidate = { invalidate() },
    requestAnimation = { postInvalidateOnAnimation() },
    currentDocumentGeneration = { documentCoordinator.generation.takeIf { documentCoordinator.hasDocument } },
    currentPageIndex = { documentCoordinator.activePageIndex.takeIf { documentCoordinator.hasDocument } },
    currentPageSwitchId = { pageSwitchRequestId.takeIf { documentCoordinator.hasDocument } },
  )
  internal val pageNavigationController = PageNavigationController(
    sessionWorker = sessionWorker,
    requestInvalidate = { invalidate() },
    requestAnimation = { postInvalidateOnAnimation() },
    currentContext = ::pageNavigationContext,
    currentViewportState = { documentController.viewportSnapshot() },
    targetPage = { index ->
      if (documentCoordinator.hasDocument) documentCoordinator.pageSnapshot(index).dimensions else null
    },
    targetInkPaths = { index ->
      if (documentCoordinator.hasDocument) documentCoordinator.pageSnapshot(index).content
        .mapNotNull { it.inkOutlineOrNull() }
        .flatMap { it.contourPathData } else emptyList()
    },
    targetTextAnnotations = { index ->
      if (documentCoordinator.hasDocument) documentCoordinator.pageSnapshot(index).content
        .mapNotNull { it.textAnnotationOrNull() } else emptyList()
    },
    fitZoomFor = documentController::usableFitZoomFor,
    previewPreparationAllowed = {
      documentCoordinator.hasDocument && !editMode && pageNavigationWindowFocus &&
        documentController.isVisibleTileCoverageComplete()
    },
    installCommittedPage = { handoff ->
      installCommittedPageSwitch(handoff)
    },
    forwardToDocumentNavigation = { event ->
      documentController.handleViewTouch(event)
    },
    onArmed = {
      performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    },
    onPageNavigationSettled = { invalidate() },
    previewScheduler = pageNavigationPreviewScheduler ?: WorkerPageNavigationPreviewScheduler(sessionWorker),
    settlementDriver = pageNavigationSettlementDriver ?:
      ValueAnimatorPageNavigationSettlementDriver { postInvalidateOnAnimation() },
  )
  internal val motionEventPredictor = lazy(LazyThreadSafetyMode.NONE) {
    predictor ?: PlatformMotionEventPredictor(this)
  }
  internal val realInputBatch = RealInputBatch()
  internal val predictedInputBatch = PredictedInputBatch()
  internal val frontBufferComposition = FrontBufferStrokeComposition()
  internal var predictionRequestCount = 0L
  internal var predictionFrameCount = 0L
  internal var predictionSuppressedCount = 0L
  internal var predictionDurationNanos = 0L
  internal val perfetto = InkPerfetto()
  private var editMode = false
  private var openHandoffInProgress = false
  private data class SnapCandidateMeasurement(
    val generation: Long,
    val pageIndex: Int,
    val candidates: List<PdfiumHorizontalSnapCandidate>,
  )
  private var snapCandidateMeasurement: SnapCandidateMeasurement? = null
  internal val isOpenHandoffInProgress: Boolean get() = openHandoffInProgress
  // Standalone test hosts are not attached to a window; explicit focus-loss callbacks still
  // gate preparation exactly like a real attached view.
  private var pageNavigationWindowFocus = true
  private var keyboardAvoidanceEnabled = true
  private var keyboardOcclusionPx = 0.0
  internal var activePointerId = noPointer
  internal var activeToolType = MotionEvent.TOOL_TYPE_UNKNOWN
  internal var latestRealEventTimeMillis: Long? = null
  internal var predictedLastEventTimeMillis = 0.0
  internal val mappedPagePoint = MutablePagePoint()
  internal var pen = PenConfiguration.DEFAULT
  internal var queuedPen: PenConfiguration? = null
  internal var lastReportedState = InkState(false, false, false)
  internal var presentationGeneration = 0L
  internal var presentationSequence = 0L
  internal var previousFrontBufferBounds: LowLatencyInkBoundsSnapshot? = null
  internal var pendingFrontBufferDirtyRegion: InkDirtyRegion? = null
  internal var latestFrontBufferAcknowledgedSequence = 0L
  /** Acknowledgements are owned by the currently active rolling composition. */
  internal var acceptsFrontBufferAcknowledgements = false
  internal var changedEventCount = 0L
  internal var incrementalRequestCount = 0L
  internal var fullResetCount = 0L
  internal var acceptedRequestCount = 0L
  internal var rejectedRequestCount = 0L
  internal var eventCount = 0L
  internal var rawRealSampleCount = 0L
  internal var realBatchCount = 0L
  internal var realNativeMutationCount = 0L
  internal var realFrameCopyCount = 0L
  internal var realFrameDecodeCount = 0L
  internal var eventAgeAtDeliveryMillis = 0L
  internal var dirtyRegionAreaPixels = 0L
  internal var dirtyRegionOutsetPx = 1
  internal var changedGeometryCount = 0L
  internal var copiedGeometryCount = 0L
  internal var cancelledCount = 0L
  internal var lastCancellationReason = CANCELLATION_NONE
  internal var disposed = false
  internal var stateNotificationsSuspended = 0
  internal var stateNotificationPending = false
  internal var committedTextLayer = TextRenderLayer.empty()
  var textAnnotationBeingEdited: (() -> String?)? = null
  var onStateChange: ((InkState) -> Unit)? = null
  var onPageChange: ((PdfPageInfo) -> Unit)? = null
  var onTextContentChanged: (() -> Unit)? = null
  var onTextTransformChanged: (() -> Unit)? = null
  var onModeChanged: (() -> Unit)? = null
  var onWindowFocusLost: (() -> Unit)? = null
  internal val isEditMode: Boolean get() = editMode

  init {
    lowLatencyInk.setPresentationAcknowledgementListener(::onFrontBufferAcknowledged)
    lowLatencyInk.setLifecycleCancellationListener {
      cancelActiveStroke(cancellationReason = CANCELLATION_LIFECYCLE)
    }
    documentController.onDoubleTapEditMode = ::enterEditModeFromDoubleTap
    documentController.onViewportChanged = {
      pageNavigationController.cancel()
      pageNavigationController.reconcilePreviews()
      onTextTransformChanged?.invoke()
    }
    documentController.onVisibleTilesReady = ::onVisibleTilesReady
    documentController.onVisibleTilesFailed = ::onVisibleTilesFailed
  }

  fun installDocumentPresentation(
    zoom: Double? = null,
    focus: PagePoint? = null,
    fitToPage: Boolean = true,
    notifyState: Boolean = false,
  ) {
    val snapshot = documentCoordinator.presentationSnapshot()
    val dimensions = snapshot.pages[snapshot.activePageIndex].dimensions
    installDocumentPresentationForPage(dimensions, zoom, focus, fitToPage, notifyState)
  }

  fun publishOpenDocumentPresentation(prepared: PreparedDocumentPresentation): PdfPageInfo {
    requireOnUiThread()
    if (disposed) throw PdfSessionException("operation_cancelled", "PDF view was disposed")
    lastReportedState = InkState(false, false, false)
    inkRenderer.clearCompleted()
    clearActivePresentation()
    clearSnapCandidateMeasurement()
    pageSwitchRequestId += 1L
    documentController.installPreparedPage(prepared.viewport)
    inkRenderer.setCompletedHistory(emptyList())
    committedTextLayer = TextRenderLayer.empty()
    editMode = false
    openHandoffInProgress = false
    invalidate()
    return prepared.pageInfo
  }

  fun beginOpenHandoff() {
    requireOnUiThread()
    if (disposed) throw PdfSessionException("operation_cancelled", "PDF view was disposed")
    openHandoffInProgress = true
    cancelActiveStroke()
    pageNavigationController.cancel()
    documentController.suspendTileRequests()
  }

  fun abortOpenHandoff() {
    requireOnUiThread()
    if (disposed) return
    openHandoffInProgress = false
    documentController.resumeTileRequests()
    invalidate()
    reconcileStateAfterOpenAbort()
  }

  fun notifyPublishedOpenDocumentPresentation() {
    requireOnUiThread()
    if (disposed) return
    documentController.resumeTileRequests()
    invalidate()
    runCatching { onTextContentChanged?.invoke() }
    runCatching { onPageChange?.invoke(currentPageInfo()) }
  }

  suspend fun awaitUsableViewportSize(): ViewportSize {
    requireOnUiThread()
    if (disposed) throw PdfSessionException("operation_cancelled", "PDF view was disposed")
    documentController.usableViewportSize()?.let { return it }
    return suspendCancellableCoroutine { continuation ->
      val removeListener = documentController.onUsableViewportSize { size ->
        if (continuation.isActive) continuation.resume(size)
      }
      continuation.invokeOnCancellation { removeListener() }
    }
  }

  fun prepareDocumentPresentation(
    info: PdfSessionInfo,
    viewport: OpenViewport,
    size: ViewportSize,
  ): PreparedDocumentPresentation {
    requireOnUiThread()
    if (disposed) throw PdfSessionException("operation_cancelled", "PDF view was disposed")
    val dimensions = info.pages.first()
    val pageViewport = PageViewport(dimensions, size)
    val target = if (viewport.fitToPage) {
      PageViewportTarget(pageViewport.fitZoom(), PagePoint(dimensions.width / 2.0, dimensions.height / 2.0))
    } else {
      checkNotNull(pageViewport.targetFor(ViewportRequest.FocusAndZoom(viewport.focus, viewport.zoom)))
    }
    pageViewport.setViewport(target.zoom, target.focus)
    return PreparedDocumentPresentation(
      viewport = pageViewport,
      pageInfo = PdfPageInfo(pageIndex = 0, pageCount = info.pageCount, dimensions = dimensions),
    )
  }

  private fun installDocumentPresentationForPage(
    dimensions: PdfPageDimensions,
    zoom: Double?,
    focus: PagePoint?,
    fitToPage: Boolean,
    notifyState: Boolean,
    notifyContent: Boolean = true,
  ) {
    requireOnUiThread()
    if (disposed) return
    cancelActiveStroke()
    pageNavigationController.cancel()
    resetDocumentHistories()
    clearSnapCandidateMeasurement()
    lastReportedState = InkState(false, false, false)
    inkRenderer.clearCompleted()
    clearActivePresentation()
    pageSwitchRequestId += 1L
    documentController.setPage(
      dimensions = dimensions,
      zoom = zoom,
      focus = focus,
      fitToPage = fitToPage,
    )
    if (documentCoordinator.hasDocument) {
      val snapshot = documentCoordinator.presentationSnapshot()
      val active = snapshot.pages[snapshot.activePageIndex]
      inkRenderer.setCompletedHistory(active.content.mapNotNull { it.inkOutlineOrNull() })
    }
    rebuildCommittedTextLayer()
    val previousState = lastReportedState
    lastReportedState = reportedState()
    if (notifyState && lastReportedState != previousState) onStateChange?.invoke(lastReportedState)
    invalidate()
    if (notifyContent) onTextContentChanged?.invoke()
  }

  fun clearDocument() {
    requireOnUiThread()
    if (disposed) return
    openHandoffInProgress = false
    cancelActiveStroke()
    pageNavigationController.cancel()
    resetDocumentHistories()
    clearSnapCandidateMeasurement()
    lastReportedState = InkState(false, false, false)
    inkRenderer.clearCompleted()
    clearActivePresentation()
    pageSwitchRequestId += 1L
    documentController.clearDocument()
    committedTextLayer = TextRenderLayer.empty()
    invalidate()
    onTextContentChanged?.invoke()
  }

  /** Publishes one fully validated structural candidate as a single UI transaction. */
  fun validateStructuralCandidate(
    info: PdfSessionInfo,
    candidatePages: List<InkPageState>,
    activePageId: String,
  ) {
    requireOnUiThread()
    if (disposed) throw PdfSessionException("operation_cancelled", "PDF view was disposed")
    if (documentCoordinator.generation != info.generation || info.pageCount != candidatePages.size ||
      candidatePages.none { it.id == activePageId } ||
      candidatePages.any { it.dimensions.width <= 0.0 || it.dimensions.height <= 0.0 }
    ) {
      throw PdfSessionException(
        "operation_cancelled",
        "The structural candidate belongs to a superseded document",
      )
    }
  }

  /** Installs a coordinator-published candidate through a non-failing presentation path. */
  fun installStructuralPresentation(): PdfPageInfo {
    requireOnUiThread()
    val state = documentCoordinator
    val snapshot = state.presentationSnapshot()
    cancelActiveStroke()
    pageNavigationController.cancel()
    pageSwitchRequestId += 1L
    val active = snapshot.pages[snapshot.activePageIndex]
    clearSnapCandidateMeasurement()
    documentController.setPage(dimensions = active.dimensions, fitToPage = true)
    inkRenderer.setCompletedHistory(active.content.mapNotNull { it.inkOutlineOrNull() })
    rebuildCommittedTextLayer()
    runCatching { notifyStateChange() }
    invalidate()
    runCatching { onTextContentChanged?.invoke() }
    return currentPageInfo().also { pageInfo ->
      runCatching { onPageChange?.invoke(pageInfo) }
    }
  }

  fun requireStructuralMutationReady(creatingDocument: Boolean = false) {
    requireOnUiThread()
    if (disposed) throw PdfSessionException("operation_cancelled", "PDF view was disposed")
    if (documentCoordinator.hasDocument == creatingDocument) {
      val message = if (creatingDocument) {
        "The view already has a document"
      } else {
        "A PDF must be opened before changing pages"
      }
      throw PdfSessionException(
        "view_not_ready",
        message,
      )
    }
    if (activePointerId != noPointer) {
      throw PdfSessionException(
        "operation_in_progress",
        "A stroke is still being completed",
      )
    }
  }

  fun currentDocumentInfo(): PdfSessionInfo {
    requireOnUiThread()
    if (disposed) {
      throw PdfSessionException(
        "operation_cancelled",
        "PDF view was disposed",
      )
    }
    val state = documentCoordinator.takeIf { it.hasDocument } ?: throw PdfSessionException(
      "view_not_ready",
      "A PDF must be opened before document inspection",
    )
    return state.sessionInfo()
  }

  fun currentPageInfo(): PdfPageInfo {
    requireOnUiThread()
    if (disposed) {
      throw PdfSessionException(
        "operation_cancelled",
        "PDF view was disposed",
      )
    }
    val state = documentCoordinator.takeIf { it.hasDocument } ?: throw PdfSessionException(
      "view_not_ready",
      "A PDF must be opened before page navigation",
    )
    return PdfPageInfo(
      pageIndex = state.activePageIndex,
      pageCount = state.pageCount,
      dimensions = state.pageSnapshot(state.activePageIndex).dimensions,
    )
  }

  /** Switches the presentation to one page without changing document generation. */
  internal fun switchPage(pageIndex: Int): PdfPageInfo {
    requireOnUiThread()
    pageNavigationController.cancel()
    return installPage(pageIndex)
  }

  private fun installPage(pageIndex: Int): PdfPageInfo {
    requireOnUiThread()
    if (disposed) {
      throw PdfSessionException(
        "operation_cancelled",
        "PDF view was disposed",
      )
    }
    val state = documentCoordinator.takeIf { it.hasDocument } ?: throw PdfSessionException(
      "view_not_ready",
      "A PDF must be opened before page navigation",
    )
    documentController.requireViewportCommandReady()
    require(pageIndex in 0 until state.pageCount) { "Invalid PDF page index: $pageIndex" }
    if (pageIndex == state.activePageIndex) return currentPageInfo()
    cancelActiveStroke()
    val target = state.activatePage(pageIndex)
    clearSnapCandidateMeasurement()
    pageSwitchRequestId += 1L
    documentController.setPage(
      dimensions = target.dimensions,
      fitToPage = true,
    )
    inkRenderer.setCompletedHistory(target.content.mapNotNull { it.inkOutlineOrNull() })
    rebuildCommittedTextLayer()
    notifyStateChange()
    invalidate()
    onTextContentChanged?.invoke()
    return currentPageInfo().also { onPageChange?.invoke(it) }
  }

  private fun installCommittedPageSwitch(handoff: PageSwitchHandoff): Boolean {
    requireOnUiThread()
    val state = documentCoordinator.takeIf { it.hasDocument } ?: return false
    if (state.generation != handoff.documentGeneration ||
      state.activePageIndex != handoff.sourcePageIndex ||
      pageSwitchRequestId + 1L != handoff.pageSwitchId ||
      handoff.targetPageIndex !in 0 until state.pageCount
    ) return false
    try {
      documentController.requireViewportCommandReady()
    } catch (_: PdfSessionException) {
      return false
    }
    cancelActiveStroke()
    val target = state.activatePage(handoff.targetPageIndex)
    clearSnapCandidateMeasurement()
    pageSwitchRequestId = handoff.pageSwitchId
    documentController.setPage(dimensions = target.dimensions, fitToPage = true)
    inkRenderer.setCompletedHistory(target.content.mapNotNull { it.inkOutlineOrNull() })
    rebuildCommittedTextLayer()
    notifyStateChange()
    invalidate()
    onTextContentChanged?.invoke()
    onPageChange?.invoke(currentPageInfo())
    return true
  }

  fun setEditMode(enabled: Boolean) {
    runOnUi {
      if (disposed) return@runOnUi
      if (editMode == enabled) return@runOnUi
      pageNavigationController.cancel()
      if (!enabled) cancelActiveStroke()
      editMode = enabled
      documentController.onEditModeChanged(enabled)
      onModeChanged?.invoke()
      if (!enabled) pageNavigationController.reconcilePreviews()
      invalidate()
    }
  }

  fun setDoubleTapConfiguration(options: DoubleTapOptions?) {
    runOnUi {
      if (disposed) return@runOnUi
      documentController.setDoubleTapConfiguration(options)
    }
  }

  fun setKeyboardAvoidanceEnabled(enabled: Boolean) {
    runOnUi {
      if (disposed) return@runOnUi
      keyboardAvoidanceEnabled = enabled
      if (!enabled) {
        keyboardOcclusionPx = 0.0
        documentController.setKeyboardOcclusion(0.0)
      }
    }
  }

  internal fun setKeyboardOcclusion(bottomPx: Double) {
    requireOnUiThread()
    if (disposed || !keyboardAvoidanceEnabled) return
    keyboardOcclusionPx = bottomPx.coerceAtLeast(0.0)
    documentController.setKeyboardOcclusion(bottomPx)
  }

  internal fun isKeyboardOccluded(): Boolean = keyboardOcclusionPx > 0.0

  internal fun ensureTextVisible(rect: PageRect, paddingPx: Double): Boolean {
    requireOnUiThread()
    return documentController.ensurePageRectVisible(rect, paddingPx)
  }

  /** Routes an editor-outside drag to viewport pan without page navigation or ink. */
  internal fun handleTextViewportTouch(event: MotionEvent) {
    requireOnUiThread()
    if (disposed) return
    documentController.handleViewTouch(event)
  }

  internal fun isTextFocusAnimating(): Boolean {
    requireOnUiThread()
    return documentController.isViewportAnimationRunning()
  }

  internal fun focusTextForEditing(rect: PageRect, caret: PageRect, paddingPx: Double): Boolean {
    requireOnUiThread()
    return documentController.focusTextForEditing(rect, caret, paddingPx)
  }

  internal fun focusTextForPlacement(
    rect: PageRect,
    caret: PageRect,
    paddingPx: Double,
    zoomAnchor: PagePoint,
  ): Boolean {
    requireOnUiThread()
    return documentController.focusTextForPlacement(rect, caret, paddingPx, zoomAnchor)
  }

  private fun enterEditModeFromDoubleTap() {
    requireOnUiThread()
    if (disposed || editMode) return
    pageNavigationController.cancel()
    editMode = true
    documentController.onEditModeChanged(true)
    onModeChanged?.invoke()
    invalidate()
  }

  private fun onVisibleTilesReady() {
    requireOnUiThread()
    val document = documentCoordinator.takeIf { it.hasDocument } ?: return
    pageNavigationController.onVisibleTilesReady(
      document.generation,
      document.activePageIndex,
      pageSwitchRequestId,
    )
    pageNavigationController.reconcilePreviews()
  }

  private fun onVisibleTilesFailed(
    generation: Long,
    pageIndex: Int,
    pageSwitchId: Long,
  ) {
    requireOnUiThread()
    pageNavigationController.onVisibleTilesFailed(generation, pageIndex, pageSwitchId)
    documentController.retryVisibleTiles()
    pageNavigationController.reconcilePreviews()
  }

  private fun pageNavigationContext(): NavigationContext? {
    requireOnUiThread()
    val document = documentCoordinator.takeIf { it.hasDocument } ?: return null
    if (editMode || width <= 0 || height <= 0) return null
    val viewport = documentController.viewportSnapshot() ?: return null
    val rtl = layoutDirection == android.view.View.LAYOUT_DIRECTION_RTL
    val eligibleTargets = buildMap<SwipeDirection, Int>(2) {
      if (document.activePageIndex > 0) {
        put(if (rtl) SwipeDirection.LEFT else SwipeDirection.RIGHT, document.activePageIndex - 1)
      }
      if (document.activePageIndex + 1 < document.pageCount) {
        put(if (rtl) SwipeDirection.RIGHT else SwipeDirection.LEFT, document.activePageIndex + 1)
      }
    }
    return NavigationContext(
      documentGeneration = document.generation,
      sourcePageIndex = document.activePageIndex,
      pageCount = document.pageCount,
      pageSwitchId = pageSwitchRequestId,
      viewportWidthPx = width,
      viewportHeightPx = height,
      density = resources.displayMetrics.density.toDouble(),
      layoutDirection = layoutDirection,
      eligibleTargets = eligibleTargets,
      targetContentRevisions = eligibleTargets.values.associateWith(document::pageHistoryRevision),
    )
  }

  internal fun pageNavigationState(): PageNavigationController.PageNavigationDiagnostics {
    requireOnUiThread()
    return pageNavigationController.diagnostics()
  }

  fun transitionToMode(enabled: Boolean, viewport: ViewportRequest) {
    requireOnUiThread()
    if (disposed) {
      throw PdfSessionException(
        "operation_cancelled",
        "PDF view was disposed",
      )
    }
    documentController.requireViewportCommandReady()
    pageNavigationController.cancel()
    cancelActiveStroke()
    editMode = false
    documentController.onEditModeChanged(false)
    onModeChanged?.invoke()
    documentController.applyViewport(viewport, animated = true)
    editMode = enabled
    documentController.onEditModeChanged(enabled)
    if (enabled) onModeChanged?.invoke()
    invalidate()
  }

  fun requireModeTransitionReady() {
    requireOnUiThread()
    if (disposed) {
      throw PdfSessionException(
        "operation_cancelled",
        "PDF view was disposed",
      )
    }
    documentController.requireViewportCommandReady()
  }

  internal fun requireTextInteractionReady() {
    requireOnUiThread()
    if (disposed) {
      throw PdfSessionException("operation_cancelled", "PDF view was disposed")
    }
    if (!documentCoordinator.hasDocument) {
      throw PdfSessionException(
        "view_not_ready",
        "A PDF must be opened before adding text",
      )
    }
    documentController.requireViewportCommandReady()
  }

  internal fun textPresentationSnapshot(): TextPresentationSnapshot? {
    requireOnUiThread()
    if (disposed) return null
    val state = documentCoordinator.takeIf { it.hasDocument } ?: return null
    val transform = documentController.pageToViewTransform() ?: return null
    val page = state.pageSnapshot(state.activePageIndex)
    return TextPresentationSnapshot(
      generation = state.generation,
      pageIndex = state.activePageIndex,
      page = page.dimensions,
      transform = transform,
      annotations = page.content.mapNotNull { it.textAnnotationOrNull() },
      snapCandidates = snapCandidateMeasurement
        ?.takeIf { it.generation == state.generation && it.pageIndex == state.activePageIndex }
        ?.candidates
        .orEmpty(),
    )
  }

  internal fun hasSnapCandidateMeasurement(generation: Long, pageIndex: Int): Boolean =
    snapCandidateMeasurement?.let {
      it.generation == generation && it.pageIndex == pageIndex
    } == true

  internal fun installSnapCandidateMeasurement(
    generation: Long,
    pageIndex: Int,
    pageSwitchId: Long,
    candidates: List<PdfiumHorizontalSnapCandidate>,
  ) {
    requireOnUiThread()
    val state = documentCoordinator.takeIf { it.hasDocument } ?: return
    if (state.generation != generation || state.activePageIndex != pageIndex ||
      pageSwitchRequestId != pageSwitchId
    ) return
    snapCandidateMeasurement = SnapCandidateMeasurement(generation, pageIndex, candidates)
  }

  private fun clearSnapCandidateMeasurement() {
    snapCandidateMeasurement = null
  }

  internal fun textTransformSnapshot(): TextTransformSnapshot? {
    requireOnUiThread()
    if (disposed) return null
    val state = documentCoordinator.takeIf { it.hasDocument } ?: return null
    val transform = documentController.pageToViewTransform() ?: return null
    val page = state.pageSnapshot(state.activePageIndex)
    return TextTransformSnapshot(
      generation = state.generation,
      pageIndex = state.activePageIndex,
      page = page.dimensions,
      transform = transform,
    )
  }

  internal fun appendTextAnnotation(
    generation: Long,
    pageIndex: Int,
    annotation: TextAnnotation,
  ) {
    validateTextMutation(generation, pageIndex)
    documentCoordinator.appendActiveText(annotation)
    rebuildCommittedTextLayer()
    notifyStateChange()
    invalidate()
    onTextContentChanged?.invoke()
  }

  internal fun replaceTextAnnotation(
    generation: Long,
    pageIndex: Int,
    before: TextAnnotation,
    after: TextAnnotation,
  ) {
    validateTextMutation(generation, pageIndex)
    documentCoordinator.replaceActiveText(before, after)
    rebuildCommittedTextLayer()
    notifyStateChange()
    invalidate()
    onTextContentChanged?.invoke()
  }

  internal fun removeTextAnnotation(
    generation: Long,
    pageIndex: Int,
    annotation: TextAnnotation,
  ) {
    validateTextMutation(generation, pageIndex)
    documentCoordinator.removeActiveText(annotation)
    rebuildCommittedTextLayer()
    notifyStateChange()
    invalidate()
    onTextContentChanged?.invoke()
  }

  fun currentViewportState(): PageViewportState {
    requireOnUiThread()
    if (disposed) {
      throw PdfSessionException(
        "operation_cancelled",
        "PDF view was disposed",
      )
    }
    return documentController.currentViewportState()
  }

  fun refreshVisibleTiles() {
    requireOnUiThread()
    if (!disposed && documentCoordinator.hasDocument) documentController.refreshVisibleTiles()
  }

  fun setPenConfiguration(
    color: String?,
    minWidth: Double?,
    maxWidth: Double?,
    smoothing: Double?,
  ) {
    val value = PenConfiguration.sanitize(
      color,
      minWidth,
      maxWidth,
      smoothing,
    )
    runOnUi {
      if (disposed) return@runOnUi
      if (activePointerId != noPointer) {
        queuedPen = value
      } else {
        installPen(value)
      }
    }
  }

  fun undo() {
    runOnUi {
      if (disposed) return@runOnUi
      pageNavigationController.cancel()
      cancelActiveStroke()
      presentHistoryMutation(documentCoordinator.undoActiveHistory())
    }
  }

  fun redo() {
    runOnUi {
      if (disposed) return@runOnUi
      pageNavigationController.cancel()
      cancelActiveStroke()
      presentHistoryMutation(documentCoordinator.redoActiveHistory())
    }
  }

  fun clear() {
    runOnUi {
      if (disposed) return@runOnUi
      pageNavigationController.cancel()
      cancelActiveStroke()
      presentHistoryMutation(documentCoordinator.clearActiveHistory())
    }
  }

  fun completedPagesSnapshot(): List<PdfPageContentSnapshot> {
    requireOnUiThread()
    return documentCoordinator.completedPagesSnapshot()
  }

  internal fun rendererDiagnostics(): InkRendererDiagnostics {
    requireOnUiThread()
    return inkRenderer.diagnostics()
  }

  fun strokeColor(): Int {
    requireOnUiThread()
    return pen.color
  }

  internal fun presentationDiagnostics(): LowLatencyInkPresentationDiagnostics {
    requireOnUiThread()
    val rolling = frontBufferComposition.retainedDiagnostics()
    return LowLatencyInkPresentationDiagnostics(
      changedEventCount = changedEventCount,
      incrementalRequestCount = incrementalRequestCount,
      fullResetCount = fullResetCount,
      acceptedRequestCount = acceptedRequestCount,
      rejectedRequestCount = rejectedRequestCount,
      frontBufferOwnsActiveInk = activePointerId != noPointer,
      eventCount = eventCount,
      rawRealSampleCount = rawRealSampleCount,
      realBatchCount = realBatchCount,
      realNativeMutationCount = realNativeMutationCount,
      realFrameCopyCount = realFrameCopyCount,
      realFrameDecodeCount = realFrameDecodeCount,
      eventAgeAtDeliveryMillis = eventAgeAtDeliveryMillis,
      dirtyRegionAreaPixels = dirtyRegionAreaPixels,
      dirtyRegionOutsetPx = dirtyRegionOutsetPx,
      changedGeometryCount = changedGeometryCount,
      copiedGeometryCount = copiedGeometryCount,
      submitToCallbackStartDurationNanos =
        lowLatencyInk.drawDiagnostics()?.submitToCallbackStartDurationNanos ?: 0L,
      offscreenRecordingDurationNanos =
        lowLatencyInk.drawDiagnostics()?.offscreenRecordingDurationNanos ?: 0L,
      frontBufferReplacementDurationNanos =
        lowLatencyInk.drawDiagnostics()?.replacementDurationNanos ?: 0L,
      handoffDurationNanos =
        lowLatencyInk.handoffDiagnostics()?.handoffDurationNanos ?: 0L,
      cancelledCount = cancelledCount,
      staleDroppedCount =
        (lowLatencyInk.drawDiagnostics()?.staleRequestCount ?: 0L) +
          (lowLatencyInk.handoffDiagnostics()?.staleCallbackCount ?: 0L),
      retainedCommittedContourCount = rolling.committedContourCount,
      retainedPredictionContourCount = rolling.predictionContourCount,
      stableBoundarySubmitted = 0L,
      stableBoundaryAcknowledged = 0L,
      lastCancellationReason = lastCancellationReason,
    )
  }

  override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
    super.onSizeChanged(width, height, oldWidth, oldHeight)
    // A viewport change invalidates both active geometry and any handoff waiting for the old
    // regular frame. Re-enter through the same generation invalidation path in either case.
    cancelActiveStroke()
    pageNavigationController.cancel()
    documentController.onSizeChanged(width, height)
    onTextTransformChanged?.invoke()
  }

  override fun onDraw(canvas: Canvas) {
    perfetto.marker("InkSign/completed draw begin")
    super.onDraw(canvas)
    canvas.drawColor(backgroundColor)
    if (disposed) return
    val navigationPresentation = pageNavigationController.presentation()
    val drawState = documentController.draw(canvas, navigationPresentation) ?: return

    InkPerfetto.section("InkSign/draw") {
      canvas.save()
      canvas.translate(navigationPresentation.translationX.toFloat(), 0f)
      canvas.scale(
        navigationPresentation.currentPageScale.toFloat(),
        navigationPresentation.currentPageScale.toFloat(),
        (width / 2f),
        (height / 2f),
      )
      inkRenderer.draw(
        canvas,
        drawState.viewScale,
        drawState.viewOffsetX,
        drawState.viewOffsetY,
        pen.color,
      )
      canvas.restore()
    }
    InkPerfetto.section("InkSign/committed text draw") {
      canvas.save()
      canvas.translate(navigationPresentation.translationX.toFloat(), 0f)
      canvas.scale(
        navigationPresentation.currentPageScale.toFloat(),
        navigationPresentation.currentPageScale.toFloat(),
        (width / 2f),
        (height / 2f),
      )
      canvas.translate(drawState.viewOffsetX.toFloat(), drawState.viewOffsetY.toFloat())
      canvas.scale(drawState.viewScale.toFloat(), drawState.viewScale.toFloat())
      committedTextLayer.draw(canvas, textAnnotationBeingEdited?.invoke())
      canvas.restore()
    }
    drawPagePreview(canvas, navigationPresentation)
    perfetto.marker("InkSign/completed ink submitted")
  }

  private fun drawPagePreview(canvas: Canvas, presentation: NavigationPresentation) {
    val preview = presentation.selectedPreview ?: return
    val rect = preview.request.targetPageRect()
    canvas.save()
    canvas.translate(presentation.targetPanelOffsetX.toFloat(), 0f)
    canvas.clipRect(0f, 0f, width.toFloat(), height.toFloat())
    canvas.drawRect(
      rect.left.toFloat(), rect.top.toFloat(), rect.right.toFloat(), rect.bottom.toFloat(),
      pagePreviewPagePaint,
    )
    canvas.clipRect(rect.left.toFloat(), rect.top.toFloat(), rect.right.toFloat(), rect.bottom.toFloat())
    canvas.drawBitmap(
      preview.bitmap,
      preview.request.bitmapLeftPx.toFloat(),
      preview.request.bitmapTopPx.toFloat(),
      pagePreviewPaint,
    )
    pagePreviewInkPaint.color = pen.color
    pagePreviewMatrix.setValues(floatArrayOf(
      preview.request.targetTransform.a.toFloat(),
      preview.request.targetTransform.c.toFloat(),
      preview.request.targetTransform.tx.toFloat(),
      preview.request.targetTransform.b.toFloat(),
      preview.request.targetTransform.d.toFloat(),
      preview.request.targetTransform.ty.toFloat(),
      0f, 0f, 1f,
    ))
    canvas.concat(pagePreviewMatrix)
    preview.request.inkPaths.forEach { path ->
      canvas.drawPath(path.toPath(), pagePreviewInkPaint)
    }
    preview.request.textLayer.draw(canvas)
    canvas.restore()
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    if (disposed) return false
    if (openHandoffInProgress) return true
    perfetto.eventReceived(event.eventTime)
    if (editMode) {
      eventCount += 1L
      eventAgeAtDeliveryMillis =
        (SystemClock.uptimeMillis() - event.eventTime).coerceAtLeast(0L)
      traceRecorder.recordInputAgeAtDelivery(eventAgeAtDeliveryMillis)
      motionEventPredictor.value.record(event)
    }
    perfetto.eventDelivered(event.eventTime)
    return InkPerfetto.section("InkSign/MotionEvent") {
      if (editMode) {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
          documentController.cancelViewportAnimation()
          requestUnbufferedDispatch(event)
        }
        handleEditEvent(event)
      } else {
        if (!pageNavigationController.onTouch(event)) documentController.handleViewTouch(event)
      }
      true
    }
  }

  override fun computeScroll() {
    super.computeScroll()
    documentController.computeScroll()
  }

  override fun onDetachedFromWindow() {
    requireOnUiThread()
    pageNavigationWindowFocus = false
    cancelActiveStroke()
    pageNavigationController.cancel()
    stopPrediction()
    inkRenderer.discardDisplayLists()
    documentController.onDetachedFromWindow()
    super.onDetachedFromWindow()
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    requireOnUiThread()
    if (disposed) return
    pageNavigationWindowFocus = true
    documentController.onAttachedToWindow()
  }

  override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
    super.onWindowFocusChanged(hasWindowFocus)
    if (disposed) return
    pageNavigationWindowFocus = hasWindowFocus
    if (hasWindowFocus) {
      pageNavigationController.reconcilePreviews()
    } else {
      cancelActiveStroke()
      pageNavigationController.cancel()
      onWindowFocusLost?.invoke()
    }
  }

  /** Releases all UI-owned state while leaving PDF resources to [sessionWorker]. */
  fun dispose() {
    requireOnUiThread()
    if (disposed) return
    disposed = true
    pageNavigationController.cancel()
    cancelActiveStroke(cancelEngineWhenIdle = true)
    documentController.dispose()
    clearSnapCandidateMeasurement()
    onPageChange = null
    resetDocumentHistories()
    pageSwitchRequestId += 1L
    lastReportedState = InkState(false, false, false)
    inkRenderer.clearCompleted()
    clearActivePresentation()
    onStateChange = null
    onTextContentChanged = null
    onTextTransformChanged = null
    onModeChanged = null
    onWindowFocusLost = null
  }

  internal fun installPen(value: PenConfiguration) {
    requireOnUiThread()
    pen = value
    invalidate()
  }

  internal fun applyQueuedPen() {
    val value = queuedPen ?: return
    queuedPen = null
    installPen(value)
  }

  private fun onFrontBufferAcknowledged(
    acknowledgement: LowLatencyInkPresentationAcknowledgement,
  ) {
    requireOnUiThread()
    if (!acceptsFrontBufferAcknowledgements) return
    if (acknowledgement.generation != presentationGeneration) return
    if (acknowledgement.sequence <= latestFrontBufferAcknowledgedSequence) return
    if (acknowledgement.sequence > presentationSequence) return
    if (!frontBufferComposition.acknowledgePresentation(
        acknowledgement.generation,
        acknowledgement.sequence,
        acknowledgement.stableBoundary,
      )
    ) return
    latestFrontBufferAcknowledgedSequence = acknowledgement.sequence
    if (acknowledgement.sequence >= presentationSequence) {
      pendingFrontBufferDirtyRegion = null
    }
  }

  internal fun recordPresentationSummary() {
    if (!traceRecorder.isRecording) return
    val diagnostics = presentationDiagnostics()
    val summary = StrokeTracePresentationSummary(
      eventCount = eventCount,
      medianInputAgeMillis = traceRecorder.medianInputAgeMillis(),
      p95InputAgeMillis = traceRecorder.p95InputAgeMillis(),
      dirtyRegionAreaPixels = diagnostics.dirtyRegionAreaPixels,
      changedGeometryCount = diagnostics.changedGeometryCount,
      copiedGeometryCount = diagnostics.copiedGeometryCount,
      submitToCallbackStartDurationNanos =
        diagnostics.submitToCallbackStartDurationNanos,
      offscreenRecordingDurationNanos = diagnostics.offscreenRecordingDurationNanos,
      frontBufferReplacementDurationNanos =
        diagnostics.frontBufferReplacementDurationNanos,
      fullResetCount = diagnostics.fullResetCount,
      staleDropCount = diagnostics.staleDroppedCount,
    )
    traceRecorder.setPresentationSummary(summary)
  }

  private fun runOnUi(action: () -> Unit) {
    if (Looper.myLooper() == Looper.getMainLooper()) action() else post(action)
  }

  internal fun requireOnUiThread() {
    check(Looper.myLooper() == Looper.getMainLooper())
  }

}
