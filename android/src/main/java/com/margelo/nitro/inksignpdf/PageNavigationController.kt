package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import kotlin.math.abs
import kotlin.math.max

/** The only transaction states used by the Android page-navigation owner. */
internal sealed interface NavigationState {
  data object Idle : NavigationState
  data class Dragging(val transaction: NavigationDragTransaction) : NavigationState
  data class Settling(val settlement: NavigationSettlement) : NavigationState
  data class Switching(
    val handoff: PageSwitchHandoff,
    val preview: PreparedPagePreview,
  ) : NavigationState
}

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
  private val sessionWorker: PdfSessionWorker,
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
  private val installCommittedPage: (PageSwitchHandoff) -> Boolean,
  private val forwardToDocumentNavigation: (MotionEvent) -> Unit,
  private val onArmed: () -> Unit,
  private val onPageNavigationSettled: () -> Unit,
  private val previewScheduler: PageNavigationPreviewScheduler =
    WorkerPageNavigationPreviewScheduler(sessionWorker),
  private val settlementDriver: PageNavigationSettlementDriver =
    ValueAnimatorPageNavigationSettlementDriver(requestAnimation),
) {
  private var state: NavigationState = NavigationState.Idle
  private var transactionToken = 0L
  private var previewEpoch = 0L
  private val slots = HashMap<SwipeDirection, PagePreviewSlot>()

  internal fun state(): NavigationState = state

  internal fun previewDirections(): Set<SwipeDirection> = slots
    .filterValues { it is PagePreviewSlot.Ready }
    .keys
    .toSet()

  internal fun handoffPending(): Boolean = state is NavigationState.Switching

  internal fun presentation(): NavigationPresentation = when (val current = state) {
    NavigationState.Idle -> NavigationPresentation()
    is NavigationState.Dragging -> current.transaction.presentation
    is NavigationState.Settling -> current.settlement.currentPresentation
    is NavigationState.Switching -> NavigationPresentation(
      direction = current.handoff.direction,
      selectedPreview = current.preview,
    )
  }

  internal fun reconcilePreviews() {
    requireOnUiThread()
    if (state != NavigationState.Idle || !previewPreparationAllowed()) return
    val nextContext = currentContext() ?: return
    nextContext.eligibleTargets.forEach { (direction, targetIndex) ->
      val target = targetPage(targetIndex) ?: return@forEach
      val revision = nextContext.targetContentRevisions[targetIndex] ?: return@forEach
      val request = pagePreviewRequest(
        generation = nextContext.documentGeneration,
        pageSwitchId = nextContext.pageSwitchId,
        sourcePageIndex = nextContext.sourcePageIndex,
        targetPageIndex = targetIndex,
        direction = direction,
        targetPage = target,
        targetZoom = fitZoomFor(target) ?: return@forEach,
        targetFocus = PagePoint(target.width / 2.0, target.height / 2.0),
        targetContentRevision = revision,
        viewportWidthPx = nextContext.viewportWidthPx,
        viewportHeightPx = nextContext.viewportHeightPx,
        density = nextContext.density,
        inkPaths = targetInkPaths(targetIndex),
        textAnnotations = targetTextAnnotations(targetIndex),
      ) ?: return@forEach
      val slot = slots[direction]
      if (slot is PagePreviewSlot.Ready && slot.preview.request.key == request.key) return@forEach
      if (slot is PagePreviewSlot.Loading && slot.request.key == request.key) return@forEach
      val preparedRequest = request.copy(
        textLayer = TextRenderLayer.from(request.textAnnotations),
      )
      replaceSlot(direction, PagePreviewSlot.Loading(preparedRequest))
      val epoch = previewEpoch
      previewScheduler.updateEpoch(nextContext.documentGeneration, epoch)
      previewScheduler.renderPreview(nextContext.documentGeneration, epoch, preparedRequest.request) { result ->
        val tile = result.getOrNull()
        val install = Runnable {
          val current = slots[direction]
          val matchingRequest = !isDisposed() && epoch == previewEpoch &&
            current is PagePreviewSlot.Loading && current.request.key == preparedRequest.key
          if (result.isFailure && matchingRequest) {
            replaceSlot(direction, PagePreviewSlot.Empty)
            requestInvalidate()
            return@Runnable
          }
          val valid = matchingRequest && tile?.request?.key == preparedRequest.request.key
          if (!valid) {
            tile?.bitmap?.recycle()
            return@Runnable
          }
          replaceSlot(direction, PagePreviewSlot.Ready(PreparedPagePreview(preparedRequest, checkNotNull(tile).bitmap)))
          replayPullIfReady(direction)
          requestInvalidate()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) install.run()
        else if (!mainHandler.post(install)) tile?.bitmap?.recycle()
      }
    }
    val validDirections = nextContext.eligibleTargets.keys
    slots.keys.toList().filter { it !in validDirections }.forEach { replaceSlot(it, PagePreviewSlot.Empty) }
  }

  internal fun onTouch(event: MotionEvent): Boolean {
    requireOnUiThread()
    if (state is NavigationState.Switching) return true
    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
      if (state is NavigationState.Settling) cancelSettleForNewPull()
      val captured = capture(event)
      if (captured == null) return false
      val (capturedContext, capturedGesture) = captured
      val needsPreviewRetry = capturedContext.eligibleTargets.any { (direction, targetPageIndex) ->
        (slots[direction] == null || slots[direction] is PagePreviewSlot.Empty) &&
          ((capturedGesture.eligibility.previous && targetPageIndex == capturedContext.sourcePageIndex - 1) ||
            (capturedGesture.eligibility.next && targetPageIndex == capturedContext.sourcePageIndex + 1))
      }
      if (needsPreviewRetry) reconcilePreviews()
      state = NavigationState.Dragging(
        NavigationDragTransaction(
          context = capturedContext,
          gesture = capturedGesture,
          latestTouchX = event.x.toDouble(),
          latestTouchY = event.y.toDouble(),
          ordinaryNavigationActive = true,
        ),
      )
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
      settleToRest()
      return true
    }
    when (event.actionMasked) {
      MotionEvent.ACTION_MOVE -> updatePull(event.x.toDouble(), event.y.toDouble())
      MotionEvent.ACTION_UP -> finishPull()
    }
    return true
  }

  internal fun cancel() {
    requireOnUiThread()
    transactionToken += 1L
    cancelSettlementDriver()
    state = NavigationState.Idle
    previewEpoch += 1L
    currentContext()?.let { previewScheduler.updateEpoch(it.documentGeneration, previewEpoch) }
    recycleAllSlots()
    onPageNavigationSettled()
    requestInvalidate()
  }

  internal fun onVisibleTilesReady(
    generation: Long,
    pageIndex: Int,
    pageSwitchId: Long,
  ) {
    requireOnUiThread()
    val current = (state as? NavigationState.Switching)?.handoff ?: return
    if (current.documentGeneration != generation || current.targetPageIndex != pageIndex ||
      current.pageSwitchId != pageSwitchId
    ) return
    state = NavigationState.Idle
    replaceSlot(current.direction, PagePreviewSlot.Empty)
    onPageNavigationSettled()
    reconcilePreviews()
    requestInvalidate()
  }

  internal fun onVisibleTilesFailed(generation: Long, pageIndex: Int, pageSwitchId: Long) {
    requireOnUiThread()
    val current = (state as? NavigationState.Switching)?.handoff ?: return
    if (current.documentGeneration != generation || current.targetPageIndex != pageIndex ||
      current.pageSwitchId != pageSwitchId
    ) return
    state = NavigationState.Idle
    replaceSlot(current.direction, PagePreviewSlot.Empty)
    onPageNavigationSettled()
    reconcilePreviews()
    requestInvalidate()
  }

  internal fun diagnostics() = PageNavigationDiagnostics(
    state = state,
    preparedDirections = previewDirections(),
    previewPresented = presentation().selectedPreview != null,
    handoffPending = state is NavigationState.Switching,
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
      if (terminal || intentResolved) discardCandidate()
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
      settleToRest()
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
      presentation = if (preview == null) {
        NavigationPresentation(direction = direction, progress = updated.progress)
      } else {
        pullPresentation(transaction.context, updated, preview)
      },
    )
    state = NavigationState.Dragging(nextTransaction)
    requestInvalidate()
  }

  private fun finishPull() {
    val current = (state as? NavigationState.Dragging)?.transaction ?: return
    if (current.ordinaryNavigationActive) return
    if (current.gesture.phase == SwipePhase.ARMED &&
      current.gesture.targetDelta != null &&
      current.selectedPreview != null
    ) {
      settleToCommit(current)
    } else {
      settleToRest()
    }
  }

  private fun pullPresentation(
    context: NavigationContext,
    pull: NavigationGesture,
    preview: PreparedPagePreview,
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
    onPageNavigationSettled()
    reconcilePreviews()
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
      failCommit(null)
      return
    }
    val pull = settlement.gesture ?: run {
      failCommit(null)
      return
    }
    val preview = settlement.preview ?: run {
      failCommit(pull.physicalDirection)
      return
    }
    val targetPage = capturedContext.eligibleTargets[pull.physicalDirection] ?: run {
      failCommit(pull.physicalDirection)
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
      failCommit(exactPageSwitchHandoff.direction)
      return
    }
    state = NavigationState.Switching(exactPageSwitchHandoff, preview)
    requestInvalidate()
  }

  private fun failCommit(direction: SwipeDirection?) {
    state = NavigationState.Idle
    direction?.let { replaceSlot(it, PagePreviewSlot.Empty) }
    onPageNavigationSettled()
    reconcilePreviews()
    requestInvalidate()
  }

  private fun cancelSettleForNewPull() {
    cancelSettlementDriver()
    state = NavigationState.Idle
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
      previous.preview.bitmap.recycle()
    }
    if (next is PagePreviewSlot.Empty) slots.remove(direction)
  }

  private fun recycleAllSlots() {
    slots.values.forEach { slot -> if (slot is PagePreviewSlot.Ready) slot.preview.bitmap.recycle() }
    slots.clear()
  }

  private fun isDisposed(): Boolean = currentContext() == null && state == NavigationState.Idle

  private fun requireOnUiThread() {
    check(Looper.myLooper() == Looper.getMainLooper())
  }

  private companion object {
    const val REST_DURATION_MS = 140L
    const val COMMIT_DURATION_MS = 180L
  }
}
