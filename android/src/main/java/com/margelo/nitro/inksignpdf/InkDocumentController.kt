package com.margelo.nitro.inksignpdf

import android.animation.ValueAnimator
import android.app.ActivityManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.widget.OverScroller
import android.view.animation.DecelerateInterpolator
import kotlin.math.max
import kotlin.math.min

/**
 * UI-thread-owned document, viewport, tile, and navigation state for
 * [SurfaceView]. The surface remains responsible for deciding when
 * navigation is allowed and for coordinating cancellation with active ink.
 */
internal class InkDocumentController(
  context: Context,
  private val sessionWorker: PdfSessionWorker,
  private val requestInvalidate: () -> Unit,
  private val requestAnimation: () -> Unit,
  private val currentDocumentGeneration: () -> Long?,
  private val currentPageIndex: () -> Int?,
  private val currentPageSwitchId: () -> Long?,
) {
  internal data class TilePresentationStateForTest(
    val activeVisibleKeys: List<PdfTileKey>,
    val activePrefetchKeys: List<PdfTileKey>,
    val displayedVisibleKeys: List<PdfTileKey>,
    val protectedVisibleKeys: Set<PdfTileKey>,
    val pendingKeys: Set<PdfTileKey>,
    val transitionPending: Boolean,
  )

  /** UI-thread-owned result consumed immediately by [SurfaceView]. */
  internal class DrawState {
    var viewScale: Double = 0.0
      private set
    var viewOffsetX: Double = 0.0
      private set
    var viewOffsetY: Double = 0.0
      private set
    internal fun set(
      viewScale: Double,
      viewOffsetX: Double,
      viewOffsetY: Double,
    ) {
      this.viewScale = viewScale
      this.viewOffsetX = viewOffsetX
      this.viewOffsetY = viewOffsetY
    }
  }

  private val pagePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
  private val tilePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    isFilterBitmap = true
    isDither = true
  }
  private val pageRect = RectF()
  private val tileRect = RectF()
  private val cache = PdfTileCache(tileCacheLimitBytes(context))
  private val scroller = OverScroller(context)
  private val gestureDetector = GestureDetector(context, GestureListener())
  private val scaleGestureDetector = ScaleGestureDetector(context, ScaleListener())
  private val mainHandler = Handler(Looper.getMainLooper())
  private val tileTopLeft = MutablePagePoint()
  private val tileBottomRight = MutablePagePoint()
  private val drawState = DrawState()
  private val density = context.resources.displayMetrics.density.toDouble()
  private var viewportSize = ViewportSize(0.0, 0.0, density)
  private var viewport: PageViewport? = null
  private var pageDimensions: PdfPageDimensions? = null
  private var scaling = false
  private var lastScrollerX = 0
  private var lastScrollerY = 0
  private var pendingKeys = HashSet<PdfTileKey>()
  private var tileRequestEpoch = 0L
  private var activeTileWindow: PdfTileWindow? = null
  private var activeVisibleTileRequests: List<PdfTileRequest> = emptyList()
  private var activePrefetchTileRequests: List<PdfTileRequest> = emptyList()
  private var displayedVisibleTileRequests: List<PdfTileRequest> = emptyList()
  private var tileLevelTransitionPending = false
  private val protectedVisibleTileKeys = HashSet<PdfTileKey>()
  private val suppressedPrefetchKeys = HashSet<PdfTileKey>()
  private var lastPlannedZoom = Double.NaN
  private var lastPlannedFocusX = Double.NaN
  private var lastPlannedFocusY = Double.NaN
  private var lastPlannedWidthPx = Double.NaN
  private var lastPlannedHeightPx = Double.NaN
  private var disposed = false
  private var viewportAnimator: ValueAnimator? = null
  private var fitToPageOnLayout = false
  private var doubleTapZoom = DEFAULT_DOUBLE_TAP_ZOOM
  private var doubleTapEntersEditMode = false
  var onDoubleTapEditMode: (() -> Unit)? = null
  var onViewportChanged: (() -> Unit)? = null
  var onVisibleTilesReady: (() -> Unit)? = null
  var onVisibleTilesFailed: ((Long, Int, Long) -> Unit)? = null

  fun setDoubleTapConfiguration(options: DoubleTapOptions?) {
    requireOnUiThread()
    if (options == null) {
      doubleTapZoom = DEFAULT_DOUBLE_TAP_ZOOM
      doubleTapEntersEditMode = false
      return
    }
    if (!options.zoom.isFinite() || options.zoom <= 0.0) return
    doubleTapZoom = options.zoom
    doubleTapEntersEditMode = options.enterEditMode == true
  }

  fun setPage(
    dimensions: PdfPageDimensions,
    zoom: Double? = null,
    focus: PagePoint? = null,
    fitToPage: Boolean = true,
  ) {
    requireOnUiThread()
    if (disposed) return
    stopViewportAnimation()
    stopFling()
    pageDimensions = dimensions
    val nextViewport = PageViewport(
      page = dimensions,
      initialSize = viewportSize,
    )
    fitToPageOnLayout = fitToPage &&
      (viewportSize.widthPx <= 0.0 || viewportSize.heightPx <= 0.0)
    if (fitToPage) {
      if (!fitToPageOnLayout) nextViewport.fit()
    } else {
      nextViewport.setZoom(zoom ?: 1.0, focus)
    }
    viewport = nextViewport
    invalidateTiles()
    requestVisibleTiles()
    requestInvalidate()
  }

  fun clearDocument() {
    requireOnUiThread()
    if (disposed) return
    stopViewportAnimation()
    stopFling()
    fitToPageOnLayout = false
    pageDimensions = null
    viewport = null
    invalidateTiles()
    requestInvalidate()
  }

  fun onSizeChanged(width: Int, height: Int) {
    requireOnUiThread()
    if (disposed) return
    viewportSize = ViewportSize(width.toDouble(), height.toDouble(), density)
    viewport?.setViewportSize(viewportSize)
    if (fitToPageOnLayout && viewportSize.widthPx > 0.0 && viewportSize.heightPx > 0.0) {
      viewport?.fit()
      fitToPageOnLayout = false
      onViewportChanged?.invoke()
      requestInvalidate()
    }
    requestVisibleTiles()
  }

  fun setKeyboardOcclusion(bottomPx: Double) {
    requireOnUiThread()
    if (disposed) return
    val currentViewport = viewport ?: return
    currentViewport.setBottomInsetPx(bottomPx)
    onViewportChanged?.invoke()
    requestVisibleTiles()
    requestInvalidate()
  }

  fun ensurePageRectVisible(rect: PageRect, paddingPx: Double): Boolean {
    requireOnUiThread()
    if (disposed) return false
    val currentViewport = viewport ?: return false
    val moved = currentViewport.ensurePageRectVisible(
      rect.left, rect.top, rect.right, rect.bottom, paddingPx,
    )
    if (moved) {
      onViewportChanged?.invoke()
      requestVisibleTiles()
      requestInvalidate()
    }
    return moved
  }

  fun isViewportAnimationRunning(): Boolean {
    requireOnUiThread()
    return viewportAnimator != null
  }

  /** Animates the current zoom to expose the editor bounds around the active caret. */
  fun focusTextForEditing(rect: PageRect, caret: PageRect, paddingPx: Double): Boolean {
    requireOnUiThread()
    if (disposed) return false
    val currentViewport = viewport ?: return false
    val target = currentViewport.targetForTextEditing(
      editorBounds = rect,
      caret = caret,
      paddingPx = paddingPx,
    )
    if (currentViewport.zoom == target.zoom && currentViewport.focus == target.focus) return false
    stopViewportAnimation()
    animateViewport(currentViewport, target)
    return true
  }

  fun onEditModeChanged(enabled: Boolean) {
    requireOnUiThread()
    if (disposed) return
    if (enabled) {
      scaling = false
      stopFling()
    }
  }

  fun requireViewportCommandReady() {
    requireOnUiThread()
    if (disposed) {
      throw PdfSessionException(
        "operation_cancelled",
        "PDF view was disposed",
      )
    }
    if (pageDimensions == null || viewport == null || viewportSize.widthPx <= 0.0 ||
      viewportSize.heightPx <= 0.0
    ) {
      throw PdfSessionException(
        "view_not_ready",
        "A loaded PDF must have a laid-out viewport",
      )
    }
  }

  fun applyViewport(request: ViewportRequest) {
    applyViewport(request, animated = false)
  }

  fun applyViewport(request: ViewportRequest, animated: Boolean) {
    requireViewportCommandReady()
    val currentViewport = checkNotNull(viewport)
    stopViewportAnimation()
    if (animated) {
      val target = currentViewport.targetFor(request)
      if (target != null &&
        (target.zoom != currentViewport.zoom || target.focus != currentViewport.focus)
      ) {
        animateViewport(currentViewport, target)
        return
      }
    }
    when (request) {
      ViewportRequest.Preserve -> Unit
      ViewportRequest.Fit -> currentViewport.fit()
      is ViewportRequest.FocusAndZoom -> {
        request.zoom?.let(currentViewport::setZoomPreservingFocus)
        request.focus?.let(currentViewport::setFocus)
      }
    }
    onViewportChanged?.invoke()
    requestVisibleTiles()
    requestInvalidate()
  }

  fun draw(
    canvas: Canvas,
    navigationPresentation: NavigationPresentation = NavigationPresentation(),
  ): DrawState? {
    requireOnUiThread()
    if (disposed) return null
    val currentViewport = viewport ?: return null
    val currentPage = pageDimensions ?: return null
    canvas.save()
    canvas.clipRect(0f, 0f, viewportSize.widthPx.toFloat(), viewportSize.heightPx.toFloat())
    canvas.translate(navigationPresentation.translationX.toFloat(), 0f)
    canvas.scale(
      navigationPresentation.currentPageScale.toFloat(),
      navigationPresentation.currentPageScale.toFloat(),
      (viewportSize.widthPx / 2.0).toFloat(),
      (viewportSize.heightPx / 2.0).toFloat(),
    )
    val transform = currentViewport.state.pageToView
    val viewScale = transform.uniformScale() ?: return null.also { canvas.restore() }
    val viewOffsetX = transform.tx
    val viewOffsetY = transform.ty
    pageRect.set(
      viewOffsetX.toFloat(),
      viewOffsetY.toFloat(),
      (viewOffsetX + currentPage.width * viewScale).toFloat(),
      (viewOffsetY + currentPage.height * viewScale).toFloat(),
    )
    canvas.drawRect(pageRect, pagePaint)

    val displayedRequests = displayedVisibleTileRequests
    if (displayedRequests.isNotEmpty()) {
      val tileToViewScale = viewScale / displayedRequests[0].scale
      displayedRequests.forEach { request ->
        val tile = cache[request.key] ?: return@forEach
        tileRect.set(
          (viewOffsetX + request.leftPx * tileToViewScale).toFloat(),
          (viewOffsetY + request.topPx * tileToViewScale).toFloat(),
          (viewOffsetX + (request.leftPx + request.widthPx) * tileToViewScale).toFloat(),
          (viewOffsetY + (request.topPx + request.heightPx) * tileToViewScale).toFloat(),
        )
        canvas.drawBitmap(tile.bitmap, null, tileRect, tilePaint)
      }
    }
    canvas.restore()
    drawState.set(viewScale, viewOffsetX, viewOffsetY)
    return drawState
  }

  fun handleViewTouch(event: MotionEvent) {
    requireOnUiThread()
    if (disposed) return
    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
      stopViewportAnimation()
      stopFling()
    }
    scaleGestureDetector.onTouchEvent(event)
    gestureDetector.onTouchEvent(event)
    if (event.actionMasked == MotionEvent.ACTION_CANCEL) {
      scaling = false
      requestVisibleTiles()
    }
  }

  fun computeScroll() {
    requireOnUiThread()
    if (disposed || !scroller.computeScrollOffset()) return
    val deltaX = scroller.currX - lastScrollerX
    val deltaY = scroller.currY - lastScrollerY
    lastScrollerX = scroller.currX
    lastScrollerY = scroller.currY
    viewport?.panBy(deltaX.toDouble(), deltaY.toDouble())
    onViewportChanged?.invoke()
    requestVisibleTiles()
    requestAnimation()
  }

  fun onAttachedToWindow() {
    requireOnUiThread()
    if (disposed) return
    requestVisibleTiles()
    requestInvalidate()
  }

  fun onDetachedFromWindow() {
    requireOnUiThread()
    if (disposed) return
    stopViewportAnimation()
    stopFling()
    invalidateTiles()
  }

  fun dispose() {
    requireOnUiThread()
    if (disposed) return
    disposed = true
    stopViewportAnimation()
    stopFling()
    pageDimensions = null
    viewport = null
    invalidateTiles()
  }

  fun mapPagePoint(
    x: Float,
    y: Float,
    destination: MutablePagePoint,
  ): Boolean {
    requireOnUiThread()
    if (!x.isFinite() || !y.isFinite()) return false
    val currentViewport = viewport ?: return false
    val currentPage = pageDimensions ?: return false
    currentViewport.viewToPage(x.toDouble(), y.toDouble(), destination)
    if (!destination.isFinite()) return false
    return destination.x >= 0.0 && destination.x <= currentPage.width &&
      destination.y >= 0.0 && destination.y <= currentPage.height
  }

  fun pageToViewTransform(): PageTransform? {
    requireOnUiThread()
    return viewport?.state?.pageToView
  }

  fun logicalDisplayUnitsPerPageUnit(): Double? {
    requireOnUiThread()
    return viewport?.state?.pageToView?.logicalDisplayUnitsPerPageUnit(density)
  }

  fun currentViewportState(): PageViewportState {
    requireViewportCommandReady()
    return checkNotNull(viewport).state
  }

  /** Immutable UI-thread snapshot captured by the page-navigation owner at touch-down. */
  internal fun viewportSnapshot(): PageViewportState? {
    requireOnUiThread()
    return viewport?.state
  }

  fun refreshVisibleTiles() {
    requireOnUiThread()
    requestVisibleTiles()
  }

  fun fitZoomFor(dimensions: PdfPageDimensions): Double {
    requireOnUiThread()
    return PageViewport(dimensions, viewportSize).fitZoom()
  }

  fun usableFitZoomFor(dimensions: PdfPageDimensions): Double? {
    requireOnUiThread()
    if (viewportSize.widthPx <= 0.0 || viewportSize.heightPx <= 0.0) return null
    val fitZoom = PageViewport(dimensions, viewportSize).fitZoom()
    return fitZoom.takeIf { it.isFinite() && it > 0.0 }
  }

  internal fun viewportStateForTest(): PageViewportState? {
    requireOnUiThread()
    return viewport?.state
  }

  /** Narrow state seam for exercising UI-owned tile handoff decisions. */
  internal fun tilePresentationStateForTest(): TilePresentationStateForTest {
    requireOnUiThread()
    return TilePresentationStateForTest(
      activeVisibleKeys = activeVisibleTileRequests.map { it.key },
      activePrefetchKeys = activePrefetchTileRequests.map { it.key },
      displayedVisibleKeys = displayedVisibleTileRequests.map { it.key },
      protectedVisibleKeys = protectedVisibleTileKeys.toSet(),
      pendingKeys = pendingKeys.toSet(),
      transitionPending = tileLevelTransitionPending,
    )
  }

  /** Reports existing coverage without changing the viewport or requesting tiles. */
  internal fun isVisibleTileCoverageComplete(): Boolean {
    requireOnUiThread()
    return activeTileWindow != null && !tileLevelTransitionPending &&
      activeVisibleTileRequests.all { cache.containsKey(it.key) }
  }

  internal fun retryVisibleTiles() {
    requireOnUiThread()
    requestVisibleTiles()
  }

  /** Sets the viewport directly for controller handoff tests without changing public API. */
  internal fun setZoomForTest(zoom: Double, focus: PagePoint? = null) {
    requireOnUiThread()
    viewport?.setZoom(zoom, focus)
    requestVisibleTiles()
  }

  private fun requestVisibleTiles() {
    requireOnUiThread()
    if (disposed) return
    InkPerfetto.section("InkSign/tile planning") {
      requestVisibleTilesInternal()
    }
  }

  private fun requestVisibleTilesInternal() {
    val currentPage = pageDimensions ?: return
    val currentViewport = viewport ?: return
    val generation = currentDocumentGeneration() ?: return
    val pageIndex = currentPageIndex() ?: return
    val pageSwitchId = currentPageSwitchId() ?: return
    val currentViewportSize = currentViewport.size
    val currentZoom = currentViewport.zoom
    val currentFocusX = currentViewport.focusX
    val currentFocusY = currentViewport.focusY
    if (currentZoom == lastPlannedZoom && currentFocusX == lastPlannedFocusX &&
      currentFocusY == lastPlannedFocusY && currentViewportSize.widthPx == lastPlannedWidthPx &&
      currentViewportSize.heightPx == lastPlannedHeightPx
    ) {
      return
    }
    lastPlannedZoom = currentZoom
    lastPlannedFocusX = currentFocusX
    lastPlannedFocusY = currentFocusY
    lastPlannedWidthPx = currentViewportSize.widthPx
    lastPlannedHeightPx = currentViewportSize.heightPx
    val nextWindow = PdfTileGrid.visibleWindow(
      page = currentPage,
      viewport = currentViewport,
      generation = generation,
      pageSwitchId = pageSwitchId,
      pageIndex = pageIndex,
      topLeft = tileTopLeft,
      bottomRight = tileBottomRight,
      previous = activeTileWindow,
    )
    if (nextWindow != activeTileWindow) {
      val previousWindow = activeTileWindow
      tileRequestEpoch += 1L
      activeTileWindow = nextWindow
      val nextVisibleRequests = ArrayList<PdfTileRequest>()
      val nextPrefetchRequests = ArrayList<PdfTileRequest>()
      nextWindow?.let(PdfTileGrid::requests)?.forEach { request ->
        if (request.priority == androidPdfTileVisiblePriority) {
          nextVisibleRequests += request
        } else {
          nextPrefetchRequests += request
        }
      }
      activeVisibleTileRequests = nextVisibleRequests
      activePrefetchTileRequests = nextPrefetchRequests
      val levelChanged = previousWindow != null && nextWindow != null &&
        previousWindow.level != nextWindow.level
      if (nextWindow == null) {
        displayedVisibleTileRequests = emptyList()
        tileLevelTransitionPending = false
      } else if (levelChanged) {
        tileLevelTransitionPending = true
      } else if (!tileLevelTransitionPending) {
        displayedVisibleTileRequests = activeVisibleTileRequests
      }
      rebuildProtectedVisibleTileKeys()
      suppressedPrefetchKeys.clear()
      sessionWorker.updateTileEpoch(generation, tileRequestEpoch)
      completeTileLevelTransitionIfCovered()
    }
    val requestEpoch = tileRequestEpoch
    var visibleRequests: ArrayList<PdfTileRequest>? = null
    activeVisibleTileRequests.forEach { request ->
      if (!cache.containsKey(request.key) &&
        pendingKeys.add(request.key)
      ) {
        val batch = visibleRequests ?: ArrayList<PdfTileRequest>().also {
          visibleRequests = it
        }
        batch += request
      }
    }
    var prefetchRequests: ArrayList<PdfTileRequest>? = null
    activePrefetchTileRequests.forEach { request ->
      if (!cache.containsKey(request.key) &&
        request.key !in suppressedPrefetchKeys &&
        pendingKeys.add(request.key)
      ) {
        val batch = prefetchRequests ?: ArrayList<PdfTileRequest>().also {
          prefetchRequests = it
        }
        batch += request
      }
    }
    visibleRequests?.let { submitTileBatch(generation, requestEpoch, it) }
    prefetchRequests?.let { submitTileBatch(generation, requestEpoch, it) }
    notifyVisibleTilesReadyIfCovered()
  }

  private fun submitTileBatch(
    generation: Long,
    requestEpoch: Long,
    requests: List<PdfTileRequest>,
  ) {
    sessionWorker.renderTiles(generation, requestEpoch, requests) { result ->
      val posted = mainHandler.post {
        requests.forEach { pendingKeys.remove(it.key) }
        if (disposed || requestEpoch != tileRequestEpoch) {
          result.getOrNull()?.forEach { it.bitmap.recycle() }
          return@post
        }
        val acceptedGeneration = currentDocumentGeneration()
        val acceptedPageIndex = currentPageIndex()
        val acceptedPageSwitchId = currentPageSwitchId()
        if (acceptedGeneration != generation ||
          acceptedPageIndex != requests.firstOrNull()?.key?.pageIndex ||
          acceptedPageSwitchId != requests.firstOrNull()?.key?.pageSwitchId
        ) {
          result.getOrNull()?.forEach { it.bitmap.recycle() }
          return@post
        }
        if (result.isFailure && requests.any { it.priority == androidPdfTileVisiblePriority }) {
          lastPlannedZoom = Double.NaN
          lastPlannedFocusX = Double.NaN
          lastPlannedFocusY = Double.NaN
          lastPlannedWidthPx = Double.NaN
          lastPlannedHeightPx = Double.NaN
          val firstRequest = checkNotNull(requests.firstOrNull())
          onVisibleTilesFailed?.invoke(
            generation,
            firstRequest.key.pageIndex,
            firstRequest.key.pageSwitchId,
          )
          requestInvalidate()
          return@post
        }
        result.onSuccess { tiles ->
          tiles.forEach { tile ->
            if (tile.request.key.generation == generation &&
              activeTileWindow?.contains(tile.request.key) == true
            ) {
              if (!cache.put(tile, protectedVisibleTileKeys) &&
                tile.request.priority == androidPdfTilePrefetchPriority
              ) {
                suppressedPrefetchKeys += tile.request.key
              }
            } else {
              tile.bitmap.recycle()
            }
          }
          if (!completeTileLevelTransitionIfCovered()) requestInvalidate()
          notifyVisibleTilesReadyIfCovered()
        }
      }
      if (!posted) result.getOrNull()?.forEach { it.bitmap.recycle() }
    }
  }

  private fun invalidateTiles() {
    tileRequestEpoch += 1L
    activeTileWindow = null
    activeVisibleTileRequests = emptyList()
    activePrefetchTileRequests = emptyList()
    displayedVisibleTileRequests = emptyList()
    tileLevelTransitionPending = false
    protectedVisibleTileKeys.clear()
    suppressedPrefetchKeys.clear()
    pendingKeys.clear()
    lastPlannedZoom = Double.NaN
    lastPlannedFocusX = Double.NaN
    lastPlannedFocusY = Double.NaN
    lastPlannedWidthPx = Double.NaN
    lastPlannedHeightPx = Double.NaN
    cache.clear()
  }

  private fun rebuildProtectedVisibleTileKeys() {
    protectedVisibleTileKeys.clear()
    activeVisibleTileRequests.forEach { request ->
      protectedVisibleTileKeys += request.key
    }
    if (tileLevelTransitionPending) {
      displayedVisibleTileRequests.forEach { request ->
        protectedVisibleTileKeys += request.key
      }
    }
  }

  private fun completeTileLevelTransitionIfCovered(): Boolean {
    if (!tileLevelTransitionPending) return false
    activeVisibleTileRequests.forEach { request ->
      if (!cache.containsKey(request.key)) return false
    }
    displayedVisibleTileRequests = activeVisibleTileRequests
    tileLevelTransitionPending = false
    rebuildProtectedVisibleTileKeys()
    cache.trimToLimit(protectedVisibleTileKeys)
    requestInvalidate()
    return true
  }

  private fun notifyVisibleTilesReadyIfCovered() {
    if (activeTileWindow == null || tileLevelTransitionPending) return
    if (activeVisibleTileRequests.all { cache.containsKey(it.key) }) {
      onVisibleTilesReady?.invoke()
    }
  }

  private fun stopFling() {
    scroller.forceFinished(true)
    lastScrollerX = 0
    lastScrollerY = 0
  }

  fun cancelViewportAnimation() {
    requireOnUiThread()
    stopViewportAnimation()
  }

  private fun animateViewport(
    currentViewport: PageViewport,
    target: PageViewportTarget,
    completion: (() -> Unit)? = null,
  ) {
    val startZoom = currentViewport.zoom
    val startFocus = currentViewport.focus
    val animator = ValueAnimator.ofFloat(0f, 1f).apply {
      duration = VIEWPORT_ANIMATION_DURATION_MS
      interpolator = DecelerateInterpolator()
      addUpdateListener { valueAnimator ->
        val progress = valueAnimator.animatedValue as Float
      currentViewport.setViewport(
          zoom = startZoom + (target.zoom - startZoom) * progress,
          focus = PagePoint(
            x = startFocus.x + (target.focus.x - startFocus.x) * progress,
            y = startFocus.y + (target.focus.y - startFocus.y) * progress,
          ),
        )
        onViewportChanged?.invoke()
        requestVisibleTiles()
        requestInvalidate()
      }
      addListener(object : android.animation.AnimatorListenerAdapter() {
        override fun onAnimationEnd(animation: android.animation.Animator) {
          if (viewportAnimator !== animation) return
          viewportAnimator = null
          currentViewport.setViewport(target.zoom, target.focus)
          onViewportChanged?.invoke()
          requestVisibleTiles()
          requestInvalidate()
          completion?.invoke()
        }

        override fun onAnimationCancel(animation: android.animation.Animator) {
          if (viewportAnimator === animation) viewportAnimator = null
        }
      })
    }
    viewportAnimator = animator
    animator.start()
  }

  private fun stopViewportAnimation() {
    viewportAnimator?.cancel()
    viewportAnimator = null
  }

  private inner class GestureListener : GestureDetector.SimpleOnGestureListener() {
    override fun onDown(event: MotionEvent): Boolean = true

    override fun onDoubleTap(event: MotionEvent): Boolean {
      val currentViewport = viewport ?: return true
      if (!currentViewport.isFitted()) {
        applyViewport(ViewportRequest.Fit, animated = true)
        return true
      }
      val target = currentViewport.zoomTo(
          event.x.toDouble(),
          event.y.toDouble(),
          doubleTapZoom,
        ) ?: return true
      animateViewport(
        currentViewport,
        target,
        completion = if (doubleTapEntersEditMode) onDoubleTapEditMode else null,
      )
      return true
    }

    override fun onScroll(
      firstEvent: MotionEvent?,
      event: MotionEvent,
      distanceX: Float,
      distanceY: Float,
    ): Boolean {
      if (scaling) return false
      viewport?.panBy(distanceX.toDouble(), distanceY.toDouble())
      onViewportChanged?.invoke()
      requestInvalidate()
      requestVisibleTiles()
      return true
    }

    override fun onFling(
      firstEvent: MotionEvent?,
      event: MotionEvent,
      velocityX: Float,
      velocityY: Float,
    ): Boolean {
      if (scaling) return false
      lastScrollerX = 0
      lastScrollerY = 0
      val flingRange = 1_000_000
      scroller.fling(
        0,
        0,
        -velocityX.toInt(),
        -velocityY.toInt(),
        -flingRange,
        flingRange,
        -flingRange,
        flingRange,
      )
      requestAnimation()
      return true
    }
  }

  private inner class ScaleListener : ScaleGestureDetector.SimpleOnScaleGestureListener() {
    override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
      scaling = true
      stopFling()
      return true
    }

    override fun onScale(detector: ScaleGestureDetector): Boolean {
      val currentViewport = viewport ?: return false
      currentViewport.zoomAround(
        detector.focusX.toDouble(),
        detector.focusY.toDouble(),
        detector.scaleFactor.toDouble(),
      )
      onViewportChanged?.invoke()
      requestVisibleTiles()
      requestInvalidate()
      return true
    }

    override fun onScaleEnd(detector: ScaleGestureDetector) {
      scaling = false
      requestVisibleTiles()
    }
  }

  private fun requireOnUiThread() {
    check(Looper.myLooper() == Looper.getMainLooper())
  }

  private companion object {
    const val DEFAULT_DOUBLE_TAP_ZOOM = 2.0
    const val VIEWPORT_ANIMATION_DURATION_MS = 160L
    const val maxTileCacheBytes = 48L * 1024L * 1024L

    fun tileCacheLimitBytes(context: Context): Long {
      val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
      val memoryLimit = activityManager?.memoryClass?.toLong()?.times(1024L * 1024L)
        ?: Runtime.getRuntime().maxMemory()
      return min(maxTileCacheBytes, max(1L, memoryLimit / 16L))
    }
  }
}
