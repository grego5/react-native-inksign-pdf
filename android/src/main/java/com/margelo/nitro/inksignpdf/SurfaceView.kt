package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Looper
import android.os.Build
import android.os.SystemClock
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.ViewTreeObserver
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
  private val pageTileFrameCommitRegistrar: ((Runnable) -> Unit)? = null,
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
  private var pagerDirectionOverride: PagerDirection? = null
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
  private var activeBasePending: Pair<Long, String>? = null
  internal val baseRasterCache: PageBaseRasterCache = PageBaseRasterCache(
    render = { generation, request, completion ->
      val scheduler = pageNavigationPreviewScheduler
      if (scheduler != null) scheduler.renderPreview(generation, request, completion)
      else sessionWorker.renderPageBase(generation, request, completion)
    },
    protectedPages = {
      if (!documentCoordinator.hasDocument) emptySet() else buildSet {
        add(documentCoordinator.activePageId())
        pageNavigationController.presentation().selectedPreview?.let { preview ->
          val index = preview.request.key.targetPageIndex
          if (index in 0 until documentCoordinator.pageCount) add(documentCoordinator.page(index).id)
        }
      }
    },
    onEvicted = { bitmap -> pageNavigationController.onPreviewEvicted(bitmap) },
    renderingAllowed = { pageId ->
      !disposed && !openHandoffInProgress && documentCoordinator.hasDocument &&
        (pageId == documentCoordinator.activePageId() || (!editMode && pageNavigationWindowFocus))
    },
    wantedPages = {
      if (!documentCoordinator.hasDocument) emptySet() else buildSet {
        add(documentCoordinator.activePageId())
        pageNavigationController.requestedPageIndex()?.let { index ->
          if (index in 0 until documentCoordinator.pageCount) add(documentCoordinator.page(index).id)
        }
      }
    },
  )
  private val cachedPreviewScheduler = object : PageNavigationPreviewScheduler {
    override fun renderPreview(generation: Long, request: PdfTileRequest,
      completion: (Result<PdfTile>) -> Unit) {
      val index = request.key.pageIndex
      if (disposed || !documentCoordinator.hasDocument || documentCoordinator.generation != generation ||
        index !in 0 until documentCoordinator.pageCount) {
        completion(Result.failure(PdfSessionException("operation_cancelled", "Page raster is stale")))
        return
      }
      val record = documentCoordinator.page(index)
      baseRasterCache.request(generation, record.id, record.dimensions, request, completion)
    }
  }

  internal val pageNavigationController: PageNavigationController = PageNavigationController(
    requestInvalidate = { invalidate() },
    requestAnimation = { postInvalidateOnAnimation() },
    currentContext = ::pageNavigationContext,
    currentViewportState = { documentController.viewportSnapshot() },
    targetPage = { index ->
      if (documentCoordinator.hasDocument) documentCoordinator.page(index).dimensions else null
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
      documentCoordinator.hasDocument && !openHandoffInProgress && !editMode && pageNavigationWindowFocus
    },
    releasePreviewBitmap = {},
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
    minimumFlingVelocityPxPerSecond = 400.0 * resources.displayMetrics.density.toDouble(),
    maximumFlingVelocityPxPerSecond = ViewConfiguration.get(context)
      .scaledMaximumFlingVelocity.toFloat(),
    previewScheduler = cachedPreviewScheduler,
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
  // gate preview acquisition exactly like a real attached view.
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
  var textAnnotationBeingEdited: (() -> Long?)? = null
  var onStateChange: ((InkState) -> Unit)? = null
  var onPageChange: ((PdfPageInfo) -> Unit)? = null
  var onZoomedInChange: ((Boolean) -> Unit)? = null
  private var zoomReportSample: Triple<String, Double, Double>? = null
  private var reportedZoomDocument: Long? = null
  private var reportedZoomedIn: Boolean? = null
  private var zoomTouchActive = false
  private val reportSettledZoom = object : Runnable {
    override fun run() {
      if (disposed) return
      if (zoomTouchActive || pageNavigationController.state() != NavigationState.Idle) {
        postDelayed(this, 120L)
        return
      }
      val sample = zoomReportSample ?: return
      val zoomedIn = sample.second > sample.third * 1.001
      val generation = documentCoordinator.generation
      if (reportedZoomDocument != generation || reportedZoomedIn != zoomedIn) {
        reportedZoomDocument = generation
        reportedZoomedIn = zoomedIn
        onZoomedInChange?.invoke(zoomedIn)
      }
    }
  }

  private fun observeZoomForReporting() {
    if (!documentCoordinator.hasDocument) return
    val page = documentCoordinator.page(documentCoordinator.activePageIndex)
    val viewport = documentController.viewportSnapshot() ?: return
    val fit = documentController.usableFitZoomFor(page.dimensions) ?: return
    val sample = Triple(page.id, viewport.zoom, fit)
    if (sample == zoomReportSample && reportedZoomDocument == documentCoordinator.generation) return
    zoomReportSample = sample
    removeCallbacks(reportSettledZoom)
    postDelayed(reportSettledZoom, 120L)
  }
  var onTextContentChanged: (() -> Unit)? = null
  var onTextTransformChanged: (() -> Unit)? = null
  var onModeChanged: (() -> Unit)? = null
  var onWindowFocusLost: (() -> Unit)? = null
  internal val isEditMode: Boolean get() = editMode

  init {
    lowLatencyInk.setPresentationAcknowledgementListener(::onFrontBufferAcknowledged)
    lowLatencyInk.setLifecycleCancellationListener {
      cancelInputGesture(cancellationReason = CANCELLATION_LIFECYCLE)
    }
    documentController.onDoubleTapEditMode = ::enterEditModeFromDoubleTap
    documentController.onViewportChanged = {
      pageNavigationController.cancelGesture()
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
    activeBasePending = null
    baseRasterCache.clear()
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
    activeBaseRaster()
    invalidate()
    return prepared.pageInfo
  }

  fun beginOpenHandoff() {
    requireOnUiThread()
    if (disposed) throw PdfSessionException("operation_cancelled", "PDF view was disposed")
    openHandoffInProgress = true
    cancelInputGesture()
    pageNavigationController.reset()
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
    cancelInputGesture()
    pageNavigationController.reset()
    activeBasePending = null
    baseRasterCache.clear()
    resetDocumentHistories()
    clearSnapCandidateMeasurement()
    lastReportedState = InkState(false, false, false)
    inkRenderer.clearCompleted()
    clearActivePresentation()
    pageSwitchRequestId += 1L
    activeBaseRaster()
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
    cancelInputGesture()
    pageNavigationController.reset()
    activeBasePending = null
    baseRasterCache.clear()
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
    cancelInputGesture()
    pageNavigationController.reset()
    activeBasePending = null
    baseRasterCache.clear()
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
    pageNavigationController.reset()
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
    cancelInputGesture()
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
    cancelInputGesture()
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
      pageNavigationController.cancelGesture()
      if (!enabled) cancelInputGesture()
      editMode = enabled
      documentController.onEditModeChanged(enabled)
      onModeChanged?.invoke()
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
  internal fun handleViewportTouch(event: MotionEvent) {
    requireOnUiThread()
    if (disposed) return
    updateZoomTouchState(event)
    documentController.handleViewTouch(event)
  }

  internal fun setCoordinatePicking(active: Boolean) {
    requireOnUiThread()
    documentController.suppressTapActions = active
  }

  internal fun pageCoordinatesAt(x: Double, y: Double): PageCoords? {
    requireOnUiThread()
    if (disposed || !documentCoordinator.hasDocument) return null
    val transform = documentController.pageToViewTransform() ?: return null
    val point = transform.inverse().map(PagePoint(x, y))
    val page = currentPageInfo()
    if (!point.x.isFinite() || !point.y.isFinite() ||
      point.x !in 0.0..page.dimensions.width || point.y !in 0.0..page.dimensions.height) return null
    return PageCoords(documentCoordinator.activePageId(), page.pageIndex.toDouble(), point.x, point.y)
  }

  private fun updateZoomTouchState(event: MotionEvent) {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> zoomTouchActive = true
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        zoomTouchActive = false
        removeCallbacks(reportSettledZoom)
        postDelayed(reportSettledZoom, 120L)
      }
    }
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
    request: ViewportRequest,
  ): Boolean {
    requireOnUiThread()
    return documentController.focusTextForPlacement(rect, caret, paddingPx, zoomAnchor, request)
  }

  private fun enterEditModeFromDoubleTap() {
    requireOnUiThread()
    if (disposed || editMode) return
    pageNavigationController.cancelGesture()
    editMode = true
    documentController.onEditModeChanged(true)
    onModeChanged?.invoke()
    invalidate()
  }

  private fun onVisibleTilesReady() {
    requireOnUiThread()
    // Cache readiness requests a draw; only a completed draw retires the preview.
    invalidate()
  }

  private var pendingTilePresentation: PageSwitchHandoff? = null
  private var pendingTileFrameCommit: Runnable? = null
  private var pendingTileFrameObserver: ViewTreeObserver? = null

  private fun cancelTilePresentationAcknowledgement() {
    val callback = pendingTileFrameCommit
    val observer = pendingTileFrameObserver
    if (Build.VERSION.SDK_INT >= 29 && callback != null && observer?.isAlive == true) {
      observer.unregisterFrameCommitCallback(callback)
    }
    pendingTilePresentation = null
    pendingTileFrameCommit = null
    pendingTileFrameObserver = null
  }

  private fun acknowledgeTilePresentation() {
    val tileEpoch = documentController.visibleTilePresentationEpoch() ?: return
    val handoff = pageNavigationController.handoff() ?: return
    if (pendingTilePresentation == handoff) return
    cancelTilePresentationAcknowledgement()
    pendingTilePresentation = handoff
    lateinit var committed: Runnable
    committed = Runnable {
      runOnUi {
        if (pendingTileFrameCommit !== committed || pendingTilePresentation != handoff) return@runOnUi
        cancelTilePresentationAcknowledgement()
        if (disposed || !documentCoordinator.hasDocument ||
          documentCoordinator.generation != handoff.documentGeneration ||
          documentCoordinator.activePageIndex != handoff.targetPageIndex ||
          pageSwitchRequestId != handoff.pageSwitchId) return@runOnUi
        if (documentController.visibleTilePresentationEpoch() != tileEpoch) {
          invalidate()
          return@runOnUi
        }
        pageNavigationController.onVisibleTilesPresented(
          handoff.documentGeneration, handoff.targetPageIndex, handoff.pageSwitchId,
        )
      }
    }
    pendingTileFrameCommit = committed
    val registrar = pageTileFrameCommitRegistrar
    if (registrar != null) {
      registrar(committed)
    } else if (Build.VERSION.SDK_INT >= 29 && isHardwareAccelerated) {
      val observer = viewTreeObserver
      pendingTileFrameObserver = observer
      observer.registerFrameCommitCallback(committed)
    } else {
      postOnAnimation(committed)
    }
  }

  private fun onVisibleTilesFailed(
    generation: Long,
    pageIndex: Int,
    pageSwitchId: Long,
  ) {
    requireOnUiThread()
    pageNavigationController.onVisibleTilesFailed(generation, pageIndex, pageSwitchId)
    documentController.retryVisibleTiles()
  }

  private fun pageNavigationContext(): NavigationContext? {
    requireOnUiThread()
    val document = documentCoordinator.takeIf { it.hasDocument } ?: return null
    if (editMode || width <= 0 || height <= 0) return null
    val viewport = documentController.viewportSnapshot() ?: return null
    val rtl = when (pagerDirectionOverride) {
      PagerDirection.LTR -> false
      PagerDirection.RTL -> true
      PagerDirection.AUTO, null -> layoutDirection == android.view.View.LAYOUT_DIRECTION_RTL
    }
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
      layoutDirection = if (rtl) android.view.View.LAYOUT_DIRECTION_RTL else android.view.View.LAYOUT_DIRECTION_LTR,
      eligibleTargets = eligibleTargets,
      targetContentRevisions = eligibleTargets.values.associateWith(document::pageHistoryRevision),
    )
  }

  internal fun setPagerDirection(direction: PagerDirection?) {
    requireOnUiThread()
    if (pagerDirectionOverride == direction) return
    pagerDirectionOverride = direction
    pageNavigationController.cancelGesture()
    invalidate()
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
    pageNavigationController.cancelGesture()
    cancelInputGesture()
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

  internal fun focusField(
    request: ViewportRequest,
    enterEditMode: Boolean,
    isCurrent: () -> Boolean,
    completion: () -> Unit,
    cancelled: () -> Unit,
  ) {
    requireModeTransitionReady()
    pageNavigationController.cancelGesture()
    cancelInputGesture()
    documentController.applyViewport(request, animated = true, completion = {
      if (isCurrent()) {
        if (enterEditMode) enterEditModeFromDoubleTap()
        completion()
      } else {
        cancelled()
      }
    }, cancelled = cancelled)
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
      pageId = page.id,
      page = page.dimensions,
      geometryRevision = state.page(state.activePageIndex).geometryRevision,
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

  internal fun appendTextAnnotationForPage(
    generation: Long,
    pageId: String,
    annotation: TextAnnotation,
  ) {
    val targetPage = resolveTextMutationPage(generation, pageId)
    documentCoordinator.appendText(
      targetPage,
      annotation,
    )
    val targetIsActive = documentCoordinator.activePageId() == targetPage.id
    if (targetIsActive) rebuildCommittedTextLayer()
    notifyStateChange()
    if (targetIsActive) {
      invalidate()
      onTextContentChanged?.invoke()
    }
  }

  internal fun replaceTextAnnotation(
    generation: Long,
    pageIndex: Int,
    before: TextAnnotation,
    after: TextAnnotation,
  ) {
    validateTextMutation(generation, pageIndex)
    documentCoordinator.replaceActiveText(
      before,
      after,
    )
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

  internal fun replaceTextAnnotationForPage(
    generation: Long,
    pageId: String,
    before: TextAnnotation,
    after: TextAnnotation,
  ) {
    val targetPage = resolveTextMutationPage(generation, pageId)
    documentCoordinator.replaceText(targetPage, before, after)
    val targetIsActive = documentCoordinator.activePageId() == targetPage.id
    if (targetIsActive) rebuildCommittedTextLayer()
    notifyStateChange()
    if (targetIsActive) {
      invalidate()
      onTextContentChanged?.invoke()
    }
  }

  internal fun removeTextAnnotationForPage(
    generation: Long,
    pageId: String,
    annotation: TextAnnotation,
  ) {
    val targetPage = resolveTextMutationPage(generation, pageId)
    targetPage.history.removeTextAnnotation(annotation)
    val targetIsActive = documentCoordinator.activePageId() == targetPage.id
    if (targetIsActive) rebuildCommittedTextLayer()
    notifyStateChange()
    if (targetIsActive) {
      invalidate()
      onTextContentChanged?.invoke()
    }
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
      pageNavigationController.cancelGesture()
      cancelInputGesture()
      presentHistoryMutation(documentCoordinator.undoActiveHistory())
    }
  }

  fun redo() {
    runOnUi {
      if (disposed) return@runOnUi
      pageNavigationController.cancelGesture()
      cancelInputGesture()
      presentHistoryMutation(documentCoordinator.redoActiveHistory())
    }
  }

  fun clear() {
    runOnUi {
      if (disposed) return@runOnUi
      pageNavigationController.cancelGesture()
      cancelInputGesture()
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

  internal fun rasterMemoryDiagnostics(): PageRasterMemoryDiagnostics {
    requireOnUiThread()
    return PageRasterMemoryDiagnostics(baseRasterCache.allocatedBytes, documentController.tileCacheBytes)
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
    // Keep the page fallback while tiles are rebuilt for the new viewport.
    cancelInputGesture()
    pageNavigationController.cancelGesture()
    documentController.onSizeChanged(width, height)
    onTextTransformChanged?.invoke()
  }

  private fun activeBaseRaster(): android.graphics.Bitmap? {
    if (disposed || !documentCoordinator.hasDocument) return null
    val page = documentCoordinator.page(documentCoordinator.activePageIndex)
    val generation = documentCoordinator.generation
    baseRasterCache.get(generation, page.id, page.dimensions)?.let { return it }
    if (openHandoffInProgress) return null
    val identity = generation to page.id
    if (activeBasePending != identity) {
      activeBasePending = identity
      val request = pageBaseRequest(PdfTileKey(generation, pageSwitchRequestId,
        documentCoordinator.activePageIndex, 0, 0, 0), page.dimensions)
      baseRasterCache.request(generation, page.id, page.dimensions, request) { result ->
        if (activeBasePending == identity) {
          activeBasePending = null
          if (result.isSuccess) invalidate()
        }
      }
    }
    return null
  }

  override fun onDraw(canvas: Canvas) {
    perfetto.marker("InkSign/completed draw begin")
    super.onDraw(canvas)
    canvas.drawColor(backgroundColor)
    if (disposed) return
    baseRasterCache.resumeDeferred()
    val navigationPresentation = pageNavigationController.presentation()
    val drawState = documentController.draw(canvas, navigationPresentation, activeBaseRaster()) ?: return
    observeZoomForReporting()

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
        checkNotNull(documentController.historyToViewTransform()),
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
      canvas.concat(checkNotNull(documentController.historyToViewTransform()).toCanvasMatrix())
      committedTextLayer.draw(canvas, textAnnotationBeingEdited?.invoke())
      canvas.restore()
    }
    drawPagePreview(canvas, navigationPresentation)
    acknowledgeTilePresentation()
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
    canvas.drawBitmap(preview.bitmap, null, android.graphics.RectF(
      rect.left.toFloat(), rect.top.toFloat(), rect.right.toFloat(), rect.bottom.toFloat(),
    ), pagePreviewPaint)
    pagePreviewInkPaint.color = pen.color
    pagePreviewMatrix.setValues(floatArrayOf(
      preview.request.historyTransform.a.toFloat(),
      preview.request.historyTransform.c.toFloat(),
      preview.request.historyTransform.tx.toFloat(),
      preview.request.historyTransform.b.toFloat(),
      preview.request.historyTransform.d.toFloat(),
      preview.request.historyTransform.ty.toFloat(),
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
    updateZoomTouchState(event)
    if (disposed) return false
    if (event.actionMasked == MotionEvent.ACTION_DOWN) inkTouchOwner = InkTouchOwner.DRAW
    if (inkTouchOwner == InkTouchOwner.DISCARD) {
      if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
        inkTouchOwner = InkTouchOwner.DRAW
      }
      return true
    }
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
        if (inkTouchOwner == InkTouchOwner.DRAW && event.actionMasked == MotionEvent.ACTION_POINTER_DOWN &&
          (0 until event.pointerCount).all { event.getToolType(it) == MotionEvent.TOOL_TYPE_FINGER }
        ) {
          cancelInputGesture()
          inkTouchOwner = InkTouchOwner.VIEWPORT
          val down = MotionEvent.obtain(event)
          down.action = MotionEvent.ACTION_DOWN
          documentController.handleViewTouch(down)
          down.recycle()
        }
        if (inkTouchOwner == InkTouchOwner.VIEWPORT) {
          documentController.handleViewTouch(event)
          if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
            inkTouchOwner = InkTouchOwner.DRAW
          }
          return@section true
        }
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

  private enum class InkTouchOwner { DRAW, VIEWPORT, DISCARD }
  private var inkTouchOwner = InkTouchOwner.DRAW

  internal fun cancelInputGesture(
    cancelEngineWhenIdle: Boolean = false,
    cancellationReason: Int = CANCELLATION_INPUT,
  ) {
    if (inkTouchOwner == InkTouchOwner.VIEWPORT) {
      inkTouchOwner = InkTouchOwner.DISCARD
      val time = SystemClock.uptimeMillis()
      val cancel = MotionEvent.obtain(time, time, MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
      updateZoomTouchState(cancel)
      documentController.handleViewTouch(cancel)
      cancel.recycle()
    }
    cancelActiveStroke(cancelEngineWhenIdle, cancellationReason)
  }

  override fun computeScroll() {
    super.computeScroll()
    documentController.computeScroll()
  }

  override fun onDetachedFromWindow() {
    requireOnUiThread()
    cancelTilePresentationAcknowledgement()
    pageNavigationWindowFocus = false
    cancelInputGesture()
    pageNavigationController.reset()
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
    if (!hasWindowFocus) {
      cancelInputGesture()
      pageNavigationController.reset()
      onWindowFocusLost?.invoke()
    }
  }

  /** Releases all UI-owned state while leaving PDF resources to [sessionWorker]. */
  fun dispose() {
    requireOnUiThread()
    if (disposed) return
    cancelTilePresentationAcknowledgement()
    disposed = true
    pageNavigationController.reset()
    activeBasePending = null
    baseRasterCache.clear()
    cancelInputGesture(cancelEngineWhenIdle = true)
    documentController.dispose()
    clearSnapCandidateMeasurement()
    onPageChange = null
    removeCallbacks(reportSettledZoom)
    onZoomedInChange = null
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
