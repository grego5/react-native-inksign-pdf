package com.margelo.nitro.inksignpdf

import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.hypot

/** Container-owned main-thread input, highlights and native Copy menu. */
internal class SourceTextSelectionController(
  private val host: FrameLayout,
  private val canvas: ViewerCanvas,
  private val scope: CoroutineScope,
  private val core: () -> DocumentCore?,
  private val eligible: () -> Boolean,
  private val annotationHit: (Float, Float) -> Boolean,
  private val cancelObservers: () -> Unit,
) {
  private data class Binding(val core: DocumentCore, val generation: Long, val pageId: String, val revision: Long)

  /**
   * Held touch-stream phase. OBSERVING passes events to children (with a long-press timer only when admitted);
   * PREPARING awaits word preparation; SELECTING, VIEWPORT and RETIRED consume the rest of the stream.
   */
  private enum class Phase { IDLE, OBSERVING, PREPARING, SELECTING, VIEWPORT, RETIRED }

  // Gesture stream.
  private var phase = Phase.IDLE
  private var pressBinding: Binding? = null
  private var pending: Job? = null
  private var token = 0L
  private var downX = 0f
  private var downY = 0f
  private var currentX = 0f
  private var currentY = 0f
  private var movedBeforeClaim = false
  private var outsideSelection = false

  // Retained selection presentation.
  private var selectionBinding: Binding? = null
  private var selection: SourceTextSelection? = null
  private var actionMode: ActionMode? = null

  private val slop = ViewConfiguration.get(host.context).scaledTouchSlop.toDouble()
  private val paint = Paint().apply { color = 0x663388FF }
  private val boxPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = 0xFF3388FF.toInt()
    style = Paint.Style.STROKE
    strokeWidth = 1.5f * host.resources.displayMetrics.density
    pathEffect = android.graphics.DashPathEffect(floatArrayOf(5f * strokeWidth, 3f * strokeWidth), 0f)
  }

  val highlights: View = object : View(host.context) {
    override fun onDraw(canvas: Canvas) { drawHighlights(canvas) }
  }.apply { isClickable = false; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }

  private val longPress = Runnable { recognize() }

  private fun currentBinding(): Binding? {
    if (!host.isAttachedToWindow || host.width <= 0 || host.height <= 0 || !eligible() || !canvas.sourceSelectionReady) return null
    val owner = core() ?: return null
    val snapshot = canvas.textTransformSnapshot() ?: return null
    return Binding(owner, snapshot.generation, canvas.documentState.activePageId(),
      canvas.documentState.pageMetadata(canvas.documentState.activePageIndex).geometryRevision)
  }

  private fun transform(): PageTransform? {
    val snapshot = canvas.textTransformSnapshot() ?: return null
    return PageCoordinates(snapshot.page).rawToView(snapshot.transform)
  }

  private fun canonical(x: Float, y: Float): PagePoint? {
    if (!x.isFinite() || !y.isFinite()) return null
    val point = transform()?.inverse()?.map(PagePoint(x.toDouble(), y.toDouble())) ?: return null
    return PagePoint(point.x, point.y)
  }

  private fun cancelPreparation() {
    token += 1
    host.removeCallbacks(longPress)
    pending?.cancel()
    pending = null
  }

  /** Stops recognition; a claimed stream stays consumed until it ends, an observed one keeps reaching children. */
  private fun retireGesture() {
    cancelPreparation()
    pressBinding = null
    when (phase) {
      Phase.VIEWPORT -> {
        val time = android.os.SystemClock.uptimeMillis()
        val cancel = MotionEvent.obtain(time, time, MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
        canvas.handleViewportTouch(cancel)
        cancel.recycle()
        phase = Phase.RETIRED
      }
      Phase.SELECTING -> phase = Phase.RETIRED
      Phase.PREPARING -> phase = Phase.OBSERVING
      Phase.IDLE, Phase.OBSERVING, Phase.RETIRED -> Unit
    }
  }

  /** Removes the selected path, its highlights and its menu; independent of the current gesture. */
  private fun clearSelection() {
    selection = null
    selectionBinding = null
    val old = actionMode
    actionMode = null
    old?.finish()
    highlights.invalidate()
  }

  private fun endStream() {
    phase = Phase.IDLE
    pressBinding = null
  }

  fun reset() {
    retireGesture()
    clearSelection()
  }

  fun presentationChanged() {
    val current = currentBinding()
    if (pressBinding != null && pressBinding != current) retireGesture()
    if (selectionBinding != null && selectionBinding != current) clearSelection()
    highlights.invalidate()
    actionMode?.invalidateContentRect()
  }

  /** Observe before children; return true only for a claimed or retired stream. */
  fun onTouch(event: MotionEvent): Boolean {
    val action = event.actionMasked
    if (action == MotionEvent.ACTION_DOWN) {
      beginStream(event)
      return false
    }
    val ends = action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL
    return when (phase) {
      Phase.IDLE -> false
      Phase.OBSERVING, Phase.PREPARING -> observe(event)
      Phase.SELECTING -> select(event)
      Phase.VIEWPORT -> {
        canvas.handleViewportTouch(event)
        if (ends) { endStream(); host.parent?.requestDisallowInterceptTouchEvent(false) }
        true
      }
      Phase.RETIRED -> {
        if (ends) { endStream(); host.parent?.requestDisallowInterceptTouchEvent(false) }
        true
      }
    }
  }

  private fun beginStream(event: MotionEvent) {
    cancelPreparation()
    if (selectionBinding != null && selectionBinding != currentBinding()) clearSelection()
    phase = Phase.OBSERVING
    currentX = event.x; currentY = event.y
    downX = event.x; downY = event.y
    movedBeforeClaim = false
    outsideSelection = visibleRectangles().none { it.contains(event.x, event.y) }
    pressBinding = currentBinding()
    if (pressBinding != null && event.pointerCount == 1 &&
      event.getToolType(0) == MotionEvent.TOOL_TYPE_FINGER && !annotationHit(event.x, event.y)) {
      host.postDelayed(longPress, ViewConfiguration.getLongPressTimeout().toLong())
    }
  }

  private fun observe(event: MotionEvent): Boolean {
    if (event.pointerCount > 1) { reset(); return false }
    currentX = event.x; currentY = event.y
    when (event.actionMasked) {
      MotionEvent.ACTION_MOVE -> {
        val moved = (0 until event.historySize).any {
          hypot((event.getHistoricalX(it) - downX).toDouble(), (event.getHistoricalY(it) - downY).toDouble()) > slop
        } || hypot((event.x - downX).toDouble(), (event.y - downY).toDouble()) > slop
        if (moved) { movedBeforeClaim = true; reset() }
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        cancelPreparation()
        if (event.actionMasked == MotionEvent.ACTION_UP && !movedBeforeClaim && outsideSelection) clearSelection()
        endStream()
      }
    }
    return false
  }

  private fun select(event: MotionEvent): Boolean {
    val action = event.actionMasked
    if (event.pointerCount > 1) {
      clearSelection()
      phase = Phase.VIEWPORT
      // Restart only viewport recognition, with a valid first-pointer DOWN followed by POINTER_DOWN.
      val properties = MotionEvent.PointerProperties().also { event.getPointerProperties(0, it) }
      val coordinates = MotionEvent.PointerCoords().also { event.getPointerCoords(0, it) }
      val down = MotionEvent.obtain(event.downTime, event.eventTime, MotionEvent.ACTION_DOWN, 1,
        arrayOf(properties), arrayOf(coordinates), event.metaState, event.buttonState,
        event.xPrecision, event.yPrecision, event.deviceId, event.edgeFlags, event.source, event.flags)
      canvas.handleViewportTouch(down)
      down.recycle()
      canvas.handleViewportTouch(event)
      return true
    }
    currentX = event.x; currentY = event.y
    if (selectionBinding != currentBinding()) { reset(); return true }
    if (action == MotionEvent.ACTION_MOVE || action == MotionEvent.ACTION_UP) {
      for (history in 0 until event.historySize) visit(event.getHistoricalX(history), event.getHistoricalY(history))
      visit(event.x, event.y)
    }
    if (action == MotionEvent.ACTION_UP) {
      endStream()
      selection?.finish()
      host.parent?.requestDisallowInterceptTouchEvent(false)
      showMenu()
    } else if (action == MotionEvent.ACTION_CANCEL) {
      endStream()
      clearSelection()
      host.parent?.requestDisallowInterceptTouchEvent(false)
    }
    return true
  }

  private fun recognize() {
    val captured = pressBinding ?: return
    if (phase != Phase.OBSERVING || captured != currentBinding()) return
    phase = Phase.PREPARING
    val gesture = token
    fun current() = phase == Phase.PREPARING && token == gesture && captured == currentBinding()
    fun abandon() { if (phase == Phase.PREPARING && token == gesture) phase = Phase.OBSERVING }
    pending = scope.launch {
      val index = try {
        captured.core.submit {
          val position = captured.core.state.pageIndexForId(captured.pageId) ?: throw operationCancelled()
          captured.core.getPage(position.toDouble()).sourceWords
        }.await()
      } catch (cancelled: CancellationException) { throw cancelled }
      catch (error: Exception) {
        android.util.Log.w("InkSignPdf", "Unable to prepare source selection", error)
        abandon()
        return@launch
      }
      if (!current()) { abandon(); return@launch }
      val point = canonical(currentX, currentY)
      val mapping = transform()
      val word = if (point == null || mapping == null) null
        else index.hit(point, 8.0 * host.resources.displayMetrics.density / hypot(mapping.a, mapping.b))
      if (point == null || word == null) { abandon(); return@launch }
      clearSelection()
      cancelObservers()
      if (!current()) { abandon(); return@launch }
      phase = Phase.SELECTING
      selectionBinding = captured
      selection = SourceTextSelection(index).also { it.begin(word) }
      host.parent?.requestDisallowInterceptTouchEvent(true)
      highlights.invalidate()
      host.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
    }
  }

  private fun operationCancelled() = PdfSessionException("operation_cancelled", "Source selection page retired")

  private fun visit(x: Float, y: Float) {
    val point = canonical(x, y) ?: return
    val path = selection ?: return
    path.updateBox(point)
    highlights.invalidate()
  }

  private fun visibleRectangles(rectangles: List<PageRect> = selection?.highlightRectangles.orEmpty()): List<android.graphics.RectF> {
    val snapshot = canvas.textTransformSnapshot() ?: return emptyList()
    val coordinates = PageCoordinates(snapshot.page)
    val mapping = coordinates.rawToView(snapshot.transform)
    val page = coordinates.rawPage
    return rectangles.mapNotNull { rect ->
      val clipped = PageRect(maxOf(0.0, rect.left), maxOf(0.0, rect.top),
        minOf(page.width, rect.right), minOf(page.height, rect.bottom))
      if (clipped.right <= clipped.left || clipped.bottom <= clipped.top) return@mapNotNull null
      val bounds = textAnnotationOuterBounds(clipped, mapping, 0.0, 0.0)
      android.graphics.RectF(bounds.left.toFloat(), bounds.top.toFloat(), bounds.right.toFloat(), bounds.bottom.toFloat())
        .takeIf { it.intersect(0f, 0f, highlights.width.toFloat(), highlights.height.toFloat()) }
    }
  }

  private fun drawHighlights(canvas: Canvas) {
    visibleRectangles().forEach { canvas.drawRect(it, paint) }
    selection?.selectionBox?.let { box -> visibleRectangles(listOf(box)).forEach { canvas.drawRect(it, boxPaint) } }
  }

  private fun showMenu() {
    if (selection?.copyText() == null || visibleRectangles().isEmpty()) return
    actionMode = host.startActionMode(object : ActionMode.Callback2() {
      override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
        menu.add(Menu.NONE, android.R.id.copy, 0, android.R.string.copy).setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
        return true
      }
      override fun onPrepareActionMode(mode: ActionMode, menu: Menu) = false
      override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
        if (actionMode !== mode || selectionBinding != currentBinding() || item.itemId != android.R.id.copy) return false
        selection?.copyText()?.let { text ->
          host.context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("PDF text", text))
        }
        clearSelection()
        return true
      }
      override fun onDestroyActionMode(mode: ActionMode) {
        if (actionMode !== mode) return
        actionMode = null
        clearSelection()
      }
      override fun onGetContentRect(mode: ActionMode, view: View, outRect: Rect) {
        val bounds = android.graphics.RectF()
        visibleRectangles().forEach(bounds::union)
        bounds.roundOut(outRect)
      }
    }, ActionMode.TYPE_FLOATING)
  }

  internal fun selectedCopyText(): String? = selection?.copyText()
}
