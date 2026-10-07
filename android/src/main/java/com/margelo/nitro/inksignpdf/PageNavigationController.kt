package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.VelocityTracker
import kotlin.math.abs
import kotlin.math.max

/** The only transaction states used by the Android page-navigation owner. */
internal sealed interface NavigationState {
  data object Idle : NavigationState
  data class Dragging(val transaction: NavigationDragTransaction) : NavigationState
  data class Settling(val settlement: NavigationSettlement) : NavigationState
}

internal data class PageNavigationHandoff(
  val handoff: PageSwitchHandoff,
  val preview: PreparedPagePreview,
)

internal sealed interface PagePreviewSlot {
  data object Empty : PagePreviewSlot
  data class Loading(val request: PagePreviewRequest) : PagePreviewSlot
  data class Ready(val preview: PreparedPagePreview) : PagePreviewSlot
}

internal data class PreparedPagePreview(
  val request: PagePreviewRequest,
  val bitmap: Bitmap,
)

internal data class NavigationContext(
  val documentGeneration: Long,
  val sourcePageIndex: Int,
  val pageCount: Int,
  val pageSwitchId: Long,
  val viewportWidthPx: Int,
  val viewportHeightPx: Int,
  val density: Double,
  val layoutDirection: Int,
  val eligibleTargets: Map<SwipeDirection, Int>,
  val targetContentRevisions: Map<Int, Long>,
)

internal data class PageSwitchHandoff(
  val documentGeneration: Long,
  val sourcePageIndex: Int,
  val targetPageIndex: Int,
  val pageSwitchId: Long,
  val direction: SwipeDirection,
  val previewKey: PagePreviewKey,
)

internal data class NavigationPresentation(
  val currentPagePreview: PreparedPagePreview? = null,
  val translationX: Double = 0.0,
  val currentPageScale: Double = 1.0,
  val direction: SwipeDirection? = null,
  val selectedPreview: PreparedPagePreview? = null,
  val targetPanelOffsetX: Double = 0.0,
  val progress: Double = 0.0,
)

internal data class NavigationDragTransaction(
  val context: NavigationContext,
  val gesture: NavigationGesture,
  val latestTouchX: Double,
  val latestTouchY: Double,
  val ordinaryNavigationActive: Boolean,
  val selectedPreview: PreparedPagePreview? = null,
  val hapticIssued: Boolean = false,
  val releaseRequested: Boolean = false,
  val presentation: NavigationPresentation = NavigationPresentation(),
)

internal enum class NavigationSettlementOutcome { REST, COMMIT }

internal class NavigationSettlement(
  val token: Long,
  val startPresentation: NavigationPresentation,
  val outcome: NavigationSettlementOutcome,
  val context: NavigationContext?,
  val gesture: NavigationGesture?,
  val preview: PreparedPagePreview?,
  var currentPresentation: NavigationPresentation = startPresentation,
  var driver: PageNavigationSettlementDriver.Handle? = null,
)

/** Places the target panel one viewport outside the opening edge. */
internal fun targetPanelOffsetX(
  direction: SwipeDirection,
  viewportWidthPx: Double,
  sharedTranslationX: Double,
): Double {
  val sign = if (direction == SwipeDirection.RIGHT) 1.0 else -1.0
  return -sign * viewportWidthPx + sharedTranslationX
}

/**
 * UI-thread owner for page-navigation gesture, preview, settlement, and handoff state.
 *
 * The document controller has no page-navigation callbacks or mutable navigation fields.
 * Its only interaction with this class is an immutable presentation passed to draw.
 */
internal class PageNavigationController(
  private val mainHandler: Handler = Handler(Looper.getMainLooper()),
  private val requestInvalidate: () -> Unit,
  private val requestAnimation: () -> Unit,
  private val currentContext: () -> NavigationContext?,
  private val currentViewportState: () -> PageViewportState?,
  private val targetPage: (Int) -> PdfPageDimensions?,
  private val targetInkPaths: (Int) -> List<InkPathData>,
  private val targetTextAnnotations: (Int) -> List<TextAnnotation>,
  private val fitZoomFor: (PdfPageDimensions) -> Double?,
  private val previewPreparationAllowed: () -> Boolean,
  private val releasePreviewBitmap: (android.graphics.Bitmap) -> Unit = { it.recycle() },
  private val installCommittedPage: (PageSwitchHandoff) -> Boolean,
  private val forwardToDocumentNavigation: (MotionEvent) -> Unit,
  private val onArmed: () -> Unit,
  private val onPageNavigationSettled: () -> Unit,
  private val previewScheduler: PageNavigationPreviewScheduler,
  private val settlementDriver: PageNavigationSettlementDriver =
    ValueAnimatorPageNavigationSettlementDriver(requestAnimation),
  private val minimumFlingVelocityPxPerSecond: Double = 400.0,
  private val maximumFlingVelocityPxPerSecond: Float = 8_000f,
) {
  private var state: NavigationState = NavigationState.Idle
  private var transactionToken = 0L
  private val slots = HashMap<SwipeDirection, PagePreviewSlot>()
  private var velocityTracker: VelocityTracker? = null

  internal fun state(): NavigationState = state

  internal fun previewDirections(): Set<SwipeDirection> = slots
    .filterValues { it is PagePreviewSlot.Ready }
    .keys
    .toSet()

  private var pendingHandoff: PageNavigationHandoff? = null

  internal fun onPreviewEvicted(bitmap: android.graphics.Bitmap) {
    requireOnUiThread()
    val retired = slots.filterValues {
      it is PagePreviewSlot.Ready && it.preview.bitmap === bitmap
    }.keys.toList()
    retired.forEach { slots.remove(it) }
    if (retired.isNotEmpty()) requestInvalidate()
  }

  internal fun handoffPending(): Boolean = pendingHandoff != null
  internal fun handoff(): PageSwitchHandoff? = pendingHandoff?.handoff

  internal fun presentation(): NavigationPresentation = (when (val current = state) {
    NavigationState.Idle -> NavigationPresentation()
    is NavigationState.Dragging -> current.transaction.presentation
    is NavigationState.Settling -> current.settlement.currentPresentation
  }).copy(currentPagePreview = pendingHandoff?.preview)

  internal fun requestedPageIndex(): Int? {
    val transaction = (state as? NavigationState.Dragging)?.transaction ?: return null
    if (transaction.ordinaryNavigationActive || transaction.gesture.phase == SwipePhase.CANDIDATE) return null
    return transaction.context.eligibleTargets[transaction.gesture.physicalDirection]
  }

  private fun requestPreview(direction: SwipeDirection, context: NavigationContext) {
    requireOnUiThread()
    if (!previewPreparationAllowed()) return
    if (slots[direction] != null) return
    val targetIndex = context.eligibleTargets[direction] ?: return
    val target = targetPage(targetIndex) ?: return
    val revision = context.targetContentRevisions[targetIndex] ?: return
    val request = pagePreviewRequest(
      generation = context.documentGeneration,
      pageSwitchId = context.pageSwitchId,
      sourcePageIndex = context.sourcePageIndex,
      targetPageIndex = targetIndex,
      direction = direction,
      targetPage = target,
      targetZoom = fitZoomFor(target) ?: return,
      targetFocus = PagePoint(target.width / 2.0, target.height / 2.0),
      targetContentRevision = revision,
      viewportWidthPx = context.viewportWidthPx,
      viewportHeightPx = context.viewportHeightPx,
      density = context.density,
      inkPaths = targetInkPaths(targetIndex),
      textAnnotations = targetTextAnnotations(targetIndex),
    ) ?: return
    val preparedRequest = request.copy(
      textAnnotations = emptyList(),
      textLayer = TextRenderLayer.from(request.textAnnotations),
    )
    val loading = PagePreviewSlot.Loading(preparedRequest)
    replaceSlot(direction, loading)
    previewScheduler.renderPreview(context.documentGeneration, preparedRequest.request) { result ->
      val tile = result.getOrNull()
      val install = Runnable {
        val current = slots[direction]
        val matchingRequest = !isDisposed() && current === loading
        if (result.isFailure && matchingRequest) {
          replaceSlot(direction, PagePreviewSlot.Empty)
          val transaction = (state as? NavigationState.Dragging)?.transaction
          if (transaction?.releaseRequested == true && transaction.gesture.physicalDirection == direction) {
            settleToRest()
          }
          requestInvalidate()
          return@Runnable
        }
        val valid = matchingRequest && tile?.request?.key == preparedRequest.request.key
        if (!valid) {
          tile?.bitmap?.let(releasePreviewBitmap)
          return@Runnable
        }
        replaceSlot(direction, PagePreviewSlot.Ready(PreparedPagePreview(preparedRequest, checkNotNull(tile).bitmap)))
        replayPullIfReady(direction)
        requestInvalidate()
      }
      if (Looper.myLooper() == Looper.getMainLooper()) install.run()
      else if (!mainHandler.post(install)) tile?.bitmap?.let(releasePreviewBitmap)
    }
  }

  internal fun onTouch(event: MotionEvent): Boolean {
    requireOnUiThread()
    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
      clearVelocityTracker()
      velocityTracker = VelocityTracker.obtain()
    }
    velocityTracker?.addMovement(event)
    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
      if (state is NavigationState.Settling) takeOverSettlement()
      val captured = capture(event)
      if (captured == null) {
        clearVelocityTracker()
        return false
      }
      val (capturedContext, capturedGesture) = captured
      state = NavigationState.Dragging(
        NavigationDragTransaction(
          context = capturedContext,
          gesture = capturedGesture,
          latestTouchX = event.x.toDouble(),
          latestTouchY = event.y.toDouble(),
          ordinaryNavigationActive = true,
        ),
      )
      recycleAllSlots()
      forwardToDocumentNavigation(event)
      return true
    }
    if (state is NavigationState.Settling) return true
    val dragging = state as? NavigationState.Dragging ?: return false
    val transaction = dragging.transaction
    if (transaction.ordinaryNavigationActive) {
      return arbitrateOrdinaryNavigation(event, transaction)
    }
    if (event.pointerCount > 1 ||
      event.actionMasked == MotionEvent.ACTION_CANCEL ||
      event.actionMasked == MotionEvent.ACTION_OUTSIDE
    ) {
      clearVelocityTracker()
      settleToRest()
      return true
    }
    when (event.actionMasked) {
      MotionEvent.ACTION_MOVE -> updatePull(event.x.toDouble(), event.y.toDouble())
      MotionEvent.ACTION_UP -> finishPull(takeVelocityX())
    }
    return true
  }

  internal fun reset() {
    cancelGesture()
    releaseHandoff()
  }

  internal fun cancelGesture() {
    requireOnUiThread()
    clearVelocityTracker()
    transactionToken += 1L
    cancelSettlementDriver()
    state = NavigationState.Idle
    recycleAllSlots()
    onPageNavigationSettled()
    requestInvalidate()
  }

  internal fun onVisibleTilesPresented(
    generation: Long,
    pageIndex: Int,
    pageSwitchId: Long,
  ) {
    requireOnUiThread()
    val current = pendingHandoff?.handoff ?: return
    if (current.documentGeneration != generation || current.targetPageIndex != pageIndex ||
      current.pageSwitchId != pageSwitchId
    ) return
    releaseHandoff()
    onPageNavigationSettled()
    requestInvalidate()
  }

  internal fun onVisibleTilesFailed(generation: Long, pageIndex: Int, pageSwitchId: Long) {
    requireOnUiThread()
    val current = pendingHandoff?.handoff ?: return
    if (current.documentGeneration != generation || current.targetPageIndex != pageIndex ||
      current.pageSwitchId != pageSwitchId
    ) return
    // A failed/partial tile batch is not presentation readiness. SurfaceView
    // retries it; retain the exact target preview until visible coverage arrives.
    requestInvalidate()
  }

  internal fun diagnostics() = PageNavigationDiagnostics(
    state = state,
    preparedDirections = previewDirections(),
    previewPresented = presentation().selectedPreview != null,
    handoffPending = pendingHandoff != null,
    translationX = presentation().translationX,
    targetPanelOffsetX = presentation().targetPanelOffsetX,
  )

  internal data class PageNavigationDiagnostics(
    val state: NavigationState,
    val preparedDirections: Set<SwipeDirection>,
    val previewPresented: Boolean,
    val handoffPending: Boolean,
    val translationX: Double,
    val targetPanelOffsetX: Double,
  )

  private fun capture(event: MotionEvent): Pair<NavigationContext, NavigationGesture>? {
    val capturedContext = currentContext() ?: return null
    val viewport = currentViewportState() ?: return null
    val page = targetPage(capturedContext.sourcePageIndex) ?: return null
    val visibleWidth = minOf(page.width, capturedContext.viewportWidthPx / (viewport.zoom * capturedContext.density))
    val captured = PageNavigationPolicy.capture(
      downX = event.x.toDouble(),
      downY = event.y.toDouble(),
      density = capturedContext.density,
      pageIndex = capturedContext.sourcePageIndex,
      pageCount = capturedContext.pageCount,
      pageWidth = page.width,
      focusX = viewport.focus.x,
      visibleWidth = visibleWidth,
      zoom = viewport.zoom,
      viewportWidthPx = capturedContext.viewportWidthPx.toDouble(),
      isRtl = capturedContext.layoutDirection == android.view.View.LAYOUT_DIRECTION_RTL,
    ) ?: return null
    if (!captured.eligibility.previous && !captured.eligibility.next) return null
    return capturedContext to captured
  }

  private fun arbitrateOrdinaryNavigation(
    event: MotionEvent,
    transaction: NavigationDragTransaction,
  ): Boolean {
    if (event.pointerCount > 1 ||
      event.actionMasked == MotionEvent.ACTION_CANCEL ||
      event.actionMasked == MotionEvent.ACTION_OUTSIDE
    ) {
      clearVelocityTracker()
      forwardToDocumentNavigation(event)
      discardCandidate()
      return true
    }

    val updated = PageNavigationPolicy.update(
      transaction.gesture,
      event.x.toDouble(),
      event.y.toDouble(),
    )
    if (updated.phase == SwipePhase.CANDIDATE) {
      forwardToDocumentNavigation(event)
      val deltaX = abs(event.x.toDouble() - transaction.gesture.downX)
      val deltaY = abs(event.y.toDouble() - transaction.gesture.downY)
      val terminal = event.actionMasked == MotionEvent.ACTION_UP
      val intentResolved = max(deltaX, deltaY) >= transaction.gesture.deadZonePx
      if (terminal || intentResolved) {
        if (terminal) clearVelocityTracker()
        discardCandidate()
      }
      else updateOrdinaryCandidate(transaction, event, updated)
      return true
    }

    val cancel = MotionEvent.obtain(event)
    cancel.action = MotionEvent.ACTION_CANCEL
    state = NavigationState.Dragging(
      transaction.copy(
        gesture = updated,
        latestTouchX = event.x.toDouble(),
        latestTouchY = event.y.toDouble(),
        ordinaryNavigationActive = false,
      ),
    )
    forwardToDocumentNavigation(cancel)
    cancel.recycle()
    updatePull(event.x.toDouble(), event.y.toDouble(), updated)
    if (event.actionMasked == MotionEvent.ACTION_UP) finishPull(takeVelocityX())
    return true
  }

  private fun updateOrdinaryCandidate(
    transaction: NavigationDragTransaction,
    event: MotionEvent,
    updated: NavigationGesture,
  ) {
    state = NavigationState.Dragging(
      transaction.copy(
        gesture = updated,
        latestTouchX = event.x.toDouble(),
        latestTouchY = event.y.toDouble(),
      ),
    )
  }

  private fun discardCandidate() {
    state = NavigationState.Idle
    requestInvalidate()
  }

  private fun updatePull(
    currentX: Double,
    currentY: Double,
    supplied: NavigationGesture? = null,
  ) {
    val dragging = state as? NavigationState.Dragging ?: return
    val transaction = dragging.transaction
    val currentGesture = transaction.gesture
    val updated = supplied ?: PageNavigationPolicy.update(currentGesture, currentX, currentY)
    if (updated.phase == SwipePhase.CANDIDATE) {
      // Neutral displacement resets presentation, not ownership of the touch stream.
      state = NavigationState.Dragging(transaction.copy(
        gesture = updated,
        latestTouchX = currentX,
        latestTouchY = currentY,
        selectedPreview = null,
        presentation = NavigationPresentation(),
      ))
      recycleAllSlots()
      requestInvalidate()
      return
    }
    val direction = updated.physicalDirection ?: return
    val slot = slots[direction]
    val preview = (slot as? PagePreviewSlot.Ready)?.preview
    val armedNow = updated.phase == SwipePhase.ARMED && preview != null && !transaction.hapticIssued
    if (armedNow) {
      onArmed()
    }
    val hapticIssued = transaction.hapticIssued || armedNow
    val nextTransaction = transaction.copy(
      gesture = updated,
      latestTouchX = currentX,
      latestTouchY = currentY,
      selectedPreview = preview,
      hapticIssued = hapticIssued,
      presentation = pullPresentation(transaction.context, updated, preview),
    )
    state = NavigationState.Dragging(nextTransaction)
    slots.keys.toList().filter { it != direction }.forEach { replaceSlot(it, PagePreviewSlot.Empty) }
    requestPreview(direction, transaction.context)
    requestInvalidate()
    if (nextTransaction.releaseRequested && preview != null) settleToCommit(nextTransaction)
  }

  private fun takeVelocityX(): Double {
    val tracker = velocityTracker ?: return 0.0
    tracker.computeCurrentVelocity(1000, maximumFlingVelocityPxPerSecond)
    val velocity = tracker.xVelocity.toDouble()
    clearVelocityTracker()
    return velocity
  }

  private fun clearVelocityTracker() {
    velocityTracker?.recycle()
    velocityTracker = null
  }

  private fun finishPull(velocityX: Double) {
    val current = (state as? NavigationState.Dragging)?.transaction ?: return
    if (current.ordinaryNavigationActive) return
    val deltaX = current.latestTouchX - current.gesture.downX
    val deltaY = current.latestTouchY - current.gesture.downY
    val flick = PageNavigationPolicy.isFling(current.gesture, deltaX, deltaY, velocityX,
      MIN_FLICK_TRAVEL_DP * current.context.density,
      minimumFlingVelocityPxPerSecond)
    if ((current.gesture.phase == SwipePhase.ARMED || flick) && current.gesture.targetDelta != null) {
      if (current.selectedPreview == null) {
        state = NavigationState.Dragging(current.copy(releaseRequested = true))
        requestPreview(checkNotNull(current.gesture.physicalDirection), current.context)
        return
      }
      settleToCommit(current)
    } else {
      clearVelocityTracker()
      settleToRest()
    }
  }

  private fun pullPresentation(
    context: NavigationContext,
    pull: NavigationGesture,
    preview: PreparedPagePreview?,
  ): NavigationPresentation {
    val direction = checkNotNull(pull.physicalDirection)
    val width = context.viewportWidthPx.toDouble()
    return NavigationPresentation(
      translationX = pull.presentationOffsetPx,
      currentPageScale = pull.presentationScale,
      direction = direction,
      selectedPreview = preview,
      targetPanelOffsetX = targetPanelOffsetX(direction, width, pull.presentationOffsetPx),
      progress = pull.progress,
    )
  }

  private fun replayPullIfReady(direction: SwipeDirection) {
    val dragging = state as? NavigationState.Dragging ?: return
    if (dragging.transaction.ordinaryNavigationActive ||
      dragging.transaction.gesture.physicalDirection != direction
    ) return
    updatePull(dragging.transaction.latestTouchX, dragging.transaction.latestTouchY)
  }

  private fun settleToRest() {
    val dragging = state as? NavigationState.Dragging ?: return
    val start = dragging.transaction.presentation
    cancelSettlementDriver()
    val token = ++transactionToken
    val settlement = NavigationSettlement(
      token = token,
      startPresentation = start,
      outcome = NavigationSettlementOutcome.REST,
      context = dragging.transaction.context,
      gesture = null,
      preview = dragging.transaction.selectedPreview,
    )
    state = NavigationState.Settling(settlement)
    if (start.translationX == 0.0) {
      finishRest(settlement)
      return
    }
    settlement.driver = settlementDriver.start(
      from = 1f,
      to = 0f,
      durationMillis = REST_DURATION_MS,
      onProgress = { amount ->
        if ((state as? NavigationState.Settling)?.settlement !== settlement ||
          token != transactionToken
        ) return@start
        settlement.currentPresentation = start.copy(
          translationX = start.translationX * amount,
          currentPageScale = start.currentPageScale + (1.0 - start.currentPageScale) * (1.0 - amount),
          targetPanelOffsetX = start.targetPanelOffsetX - start.translationX * (1.0 - amount),
          progress = start.progress * amount,
        )
        requestInvalidate()
      },
      onEnd = {
        if ((state as? NavigationState.Settling)?.settlement !== settlement ||
          token != transactionToken
        ) return@start
        settlement.driver = null
        finishRest(settlement)
      },
    )
  }

  private fun finishRest(settlement: NavigationSettlement) {
    if ((state as? NavigationState.Settling)?.settlement !== settlement) return
    state = NavigationState.Idle
    recycleAllSlots()
    onPageNavigationSettled()
    requestInvalidate()
  }

  private fun settleToCommit(transaction: NavigationDragTransaction) {
    val preview = transaction.selectedPreview ?: run {
      settleToRest()
      return
    }
    val direction = checkNotNull(transaction.gesture.physicalDirection)
    val sign = if (direction == SwipeDirection.RIGHT) 1.0 else -1.0
    val start = transaction.presentation
    val targetTranslation = sign * transaction.context.viewportWidthPx.toDouble()
    cancelSettlementDriver()
    val token = ++transactionToken
    val settlement = NavigationSettlement(
      token = token,
      startPresentation = start,
      outcome = NavigationSettlementOutcome.COMMIT,
      context = transaction.context,
      gesture = transaction.gesture,
      preview = preview,
    )
    state = NavigationState.Settling(settlement)
    settlement.driver = settlementDriver.start(
      from = 0f,
      to = 1f,
      durationMillis = COMMIT_DURATION_MS,
      onProgress = { amount ->
        if ((state as? NavigationState.Settling)?.settlement !== settlement ||
          token != transactionToken
        ) return@start
        val translation = start.translationX + (targetTranslation - start.translationX) * amount
        settlement.currentPresentation = start.copy(
          translationX = translation,
          currentPageScale = start.currentPageScale + (0.96 - start.currentPageScale) * amount,
          targetPanelOffsetX = targetPanelOffsetX(
            direction,
            transaction.context.viewportWidthPx.toDouble(),
            translation,
          ),
          progress = 1.0,
          selectedPreview = preview,
        )
        requestInvalidate()
      },
      onEnd = {
        if ((state as? NavigationState.Settling)?.settlement !== settlement ||
          token != transactionToken
        ) return@start
        settlement.driver = null
        commit(settlement)
      },
    )
  }

  private fun commit(settlement: NavigationSettlement) {
    val capturedContext = settlement.context ?: run {
      failCommit()
      return
    }
    val pull = settlement.gesture ?: run {
      failCommit()
      return
    }
    val preview = settlement.preview ?: run {
      failCommit()
      return
    }
    val targetPage = capturedContext.eligibleTargets[pull.physicalDirection] ?: run {
      failCommit()
      return
    }
    val exactPageSwitchHandoff = PageSwitchHandoff(
      documentGeneration = capturedContext.documentGeneration,
      sourcePageIndex = capturedContext.sourcePageIndex,
      targetPageIndex = targetPage,
      pageSwitchId = capturedContext.pageSwitchId + 1L,
      direction = checkNotNull(pull.physicalDirection),
      previewKey = preview.request.key,
    )
    val installed = try {
      installCommittedPage(exactPageSwitchHandoff)
    } catch (_: PdfSessionException) {
      false
    }
    if (!installed) {
      failCommit()
      return
    }
    // The installed page owns this fallback independently of the next touch stream.
    slots.remove(exactPageSwitchHandoff.direction)
    releaseHandoff()
    pendingHandoff = PageNavigationHandoff(exactPageSwitchHandoff, preview)
    state = NavigationState.Idle
    recycleAllSlots()
    onPageNavigationSettled()
    requestInvalidate()
  }

  private fun failCommit() {
    state = NavigationState.Idle
    recycleAllSlots()
    onPageNavigationSettled()
    requestInvalidate()
  }

  private fun takeOverSettlement() {
    val settlement = (state as NavigationState.Settling).settlement
    cancelSettlementDriver()
    if (settlement.outcome == NavigationSettlementOutcome.COMMIT) {
      commit(settlement)
    } else {
      state = NavigationState.Idle
      recycleAllSlots()
      requestInvalidate()
    }
  }

  private fun cancelSettlementDriver() {
    val settlement = (state as? NavigationState.Settling)?.settlement ?: return
    val animator = settlement.driver ?: return
    settlement.driver = null
    transactionToken += 1L
    animator.cancel()
  }

  private fun replaceSlot(direction: SwipeDirection, next: PagePreviewSlot) {
    val previous = slots.put(direction, next)
    if (previous is PagePreviewSlot.Ready && previous.preview.bitmap !== (next as? PagePreviewSlot.Ready)?.preview?.bitmap) {
      releasePreviewBitmap(previous.preview.bitmap)
    }
    if (next is PagePreviewSlot.Empty) slots.remove(direction)
  }

  private fun releaseHandoff() {
    pendingHandoff?.preview?.bitmap?.let(releasePreviewBitmap)
    pendingHandoff = null
  }

  private fun recycleAllSlots() {
    slots.values.forEach { slot -> if (slot is PagePreviewSlot.Ready) releasePreviewBitmap(slot.preview.bitmap) }
    slots.clear()
  }

  private fun isDisposed(): Boolean = currentContext() == null && state == NavigationState.Idle

  private fun requireOnUiThread() {
    check(Looper.myLooper() == Looper.getMainLooper())
  }

  private companion object {
    const val MIN_FLICK_TRAVEL_DP = 25.0
    const val REST_DURATION_MS = 140L
    const val COMMIT_DURATION_MS = 180L
  }
}
