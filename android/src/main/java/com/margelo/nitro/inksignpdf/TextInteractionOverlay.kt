package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.text.InputType
import android.text.Editable
import android.text.TextWatcher
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewTreeObserver
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.max
import java.util.UUID

internal const val defaultTextFontSize = 16.0
internal const val minimumTextFontSize = 8.0
internal const val maximumTextFontSize = 72.0
internal const val minimumTextEditorWidthEm = 1.0
internal const val textEditorHorizontalPaddingRatio = 0.375
internal const val textEditorVerticalPaddingRatio = 0.25

internal fun textEditorPaddingPx(fontSizePx: Double, ratio: Double): Int =
  max(1, ceil(fontSizePx * ratio).toInt())

internal fun textEditorMinimumContentWidth(fontSize: Double): Double =
  fontSize * minimumTextEditorWidthEm

internal fun normalizeTextFontSize(value: Double?): Double =
  value
    ?.takeIf { it.isFinite() && it > 0.0 }
    ?.coerceIn(minimumTextFontSize, maximumTextFontSize)
    ?: defaultTextFontSize

internal data class TextPresentationSnapshot(
  val generation: Long,
  val pageIndex: Int,
  val page: PdfPageDimensions,
  val transform: PageTransform,
  val annotations: List<TextAnnotation>,
  val snapCandidates: List<PdfiumHorizontalSnapCandidate> = emptyList(),
)

internal data class TextTransformSnapshot(
  val generation: Long,
  val pageIndex: Int,
  val page: PdfPageDimensions,
  val transform: PageTransform,
)

internal sealed interface TextEditingMutation {
  data object NoOp : TextEditingMutation
  data class Append(val annotation: TextAnnotation) : TextEditingMutation
  data class Replace(
    val before: TextAnnotation,
    val after: TextAnnotation,
  ) : TextEditingMutation
  data class Remove(val annotation: TextAnnotation) : TextEditingMutation
}

internal fun settleTextEditing(
  original: TextAnnotation?,
  finished: TextAnnotation?,
): TextEditingMutation = when {
  original == null && finished == null -> TextEditingMutation.NoOp
  original == null -> TextEditingMutation.Append(checkNotNull(finished))
  finished == null -> TextEditingMutation.Remove(original)
  original == finished -> TextEditingMutation.NoOp
  else -> TextEditingMutation.Replace(original, finished)
}

/** Chooses the selection endpoint that native visibility should follow. */
internal fun activeSelectionOffsetAfterChange(
  previousStart: Int?,
  previousEnd: Int?,
  previousActive: Int,
  start: Int,
  end: Int,
): Int {
  if (start == end) return start
  if (previousStart == null || previousEnd == null) return end
  val startChanged = start != previousStart
  val endChanged = end != previousEnd
  return when {
    startChanged != endChanged -> if (startChanged) start else end
    previousActive == previousStart && previousStart != previousEnd -> start
    previousActive == previousEnd && previousStart != previousEnd -> end
    else -> end
  }
}

internal fun clampTextAnnotationPosition(
  position: PagePoint,
  size: TextIntrinsicSize,
  page: PdfPageDimensions,
): PagePoint {
  val x = if (size.width > page.width) {
    (page.width - size.width) / 2.0
  } else {
    position.x.coerceIn(0.0, page.width - size.width)
  }
  val y = if (size.height > page.height) {
    (page.height - size.height) / 2.0
  } else {
    position.y.coerceIn(0.0, page.height - size.height)
  }
  return PagePoint(x, y)
}

internal fun textEditorIntrinsicSize(text: String, fontSize: Double): TextIntrinsicSize {
  val measured = TextLayoutSpec.measure(text, fontSize)
  return measured.copy(width = max(measured.width, textEditorMinimumContentWidth(fontSize)))
}

internal fun chooseTextPlacementPosition(
  pagePoint: PagePoint,
  size: TextIntrinsicSize,
  page: PdfPageDimensions,
  horizontalPadding: Double,
  verticalPadding: Double,
): PagePoint {
  val contentLeft = pagePoint.x - size.width / 2.0
  val contentTop = pagePoint.y - size.height
  val frame = textEditorFrameBounds(
    PageRect(contentLeft, contentTop, contentLeft + size.width, contentTop + size.height),
    horizontalPadding,
    verticalPadding,
    horizontalPadding,
  )
  val boundedFrame = clampTextAnnotationPosition(
    PagePoint(frame.left, frame.top),
    TextIntrinsicSize(frame.right - frame.left, frame.bottom - frame.top),
    page,
  )
  return PagePoint(
    contentLeft + boundedFrame.x - frame.left,
    contentTop + boundedFrame.y - frame.top,
  )
}

internal fun nearestTextSnapCandidate(
  pagePoint: PagePoint,
  transform: PageTransform,
  candidates: List<PdfiumHorizontalSnapCandidate>,
  maximumDistancePx: Double,
): PdfiumHorizontalSnapCandidate? {
  val touchY = transform.map(pagePoint).y
  return candidates.asSequence()
    .filter { pagePoint.x in it.left..it.right }
    .map { candidate ->
      candidate to abs(transform.map(PagePoint(pagePoint.x, candidate.y)).y - touchY)
    }
    .filter { (_, distancePx) -> distancePx <= maximumDistancePx }
    .minByOrNull { it.second }
    ?.first
}

internal fun textAnnotationOuterBounds(
  bounds: PageRect,
  transform: PageTransform,
  horizontalPaddingPx: Double,
  verticalPaddingPx: Double,
): PageRect {
  val corners = listOf(
    transform.map(PagePoint(bounds.left, bounds.top)),
    transform.map(PagePoint(bounds.right, bounds.top)),
    transform.map(PagePoint(bounds.left, bounds.bottom)),
    transform.map(PagePoint(bounds.right, bounds.bottom)),
  )
  return PageRect(
    corners.minOf { it.x } - horizontalPaddingPx,
    corners.minOf { it.y } - verticalPaddingPx,
    corners.maxOf { it.x } + horizontalPaddingPx,
    corners.maxOf { it.y } + verticalPaddingPx,
  )
}

internal fun textAnnotationOuterRect(
  bounds: PageRect,
  transform: PageTransform,
  horizontalPaddingPx: Float,
  verticalPaddingPx: Float,
): RectF = textAnnotationOuterBounds(
  bounds,
  transform,
  horizontalPaddingPx.toDouble(),
  verticalPaddingPx.toDouble(),
).let { outer ->
  RectF(
    outer.left.toFloat(),
    outer.top.toFloat(),
    outer.right.toFloat(),
    outer.bottom.toFloat(),
  )
}

/** Bounds the live editor to the remaining canonical page width. */
internal fun textEditorPageBoundedSize(
  intrinsic: TextIntrinsicSize,
  minimumPageSize: Double,
  pageLeft: Double?,
  pageRight: Double?,
  anchorX: Double?,
  isRtl: Boolean,
): TextIntrinsicSize = TextIntrinsicSize(
  width = max(intrinsic.width, minimumPageSize).let { width ->
    val pageEdge = if (isRtl) pageLeft else pageRight
    if (pageEdge != null && anchorX != null &&
      pageEdge.isFinite() && anchorX.isFinite()
    ) minOf(width, (if (isRtl) anchorX - pageEdge else pageEdge - anchorX).coerceAtLeast(1.0)) else width
  },
  height = max(intrinsic.height, minimumPageSize),
)

internal fun textEditorPageBounds(
  anchorX: Double,
  positionY: Double,
  size: TextIntrinsicSize,
  isRtl: Boolean,
): PageRect = if (isRtl) {
  PageRect(anchorX - size.width, positionY, anchorX, positionY + size.height)
} else {
  PageRect(anchorX, positionY, anchorX + size.width, positionY + size.height)
}

/** Positions the padded editor so its glyph origin matches committed text. */
internal fun textEditorFrameBounds(
  bounds: PageRect,
  leftPadding: Double,
  topPadding: Double,
  rightPadding: Double,
  bottomPadding: Double = topPadding,
): PageRect {
  return PageRect(
    bounds.left - leftPadding,
    bounds.top - topPadding,
    bounds.right + rightPadding,
    bounds.bottom + bottomPadding,
  )
}

/** Flips the anchored edge without moving the current editor rectangle. */
internal fun textEditorAnchorAfterDirectionChange(
  transform: PageTransform,
  frameEdge: ViewPoint,
  willBeRtl: Boolean,
  paddingLeftPx: Double,
  paddingTopPx: Double,
  paddingRightPx: Double,
): Double {
  val anchorInView = if (willBeRtl) {
    ViewPoint(frameEdge.x - paddingRightPx, frameEdge.y + paddingTopPx)
  } else {
    ViewPoint(frameEdge.x + paddingLeftPx, frameEdge.y + paddingTopPx)
  }
  return transform.unmap(anchorInView).x
}

internal fun localImeOverlapPx(
  viewTopInWindow: Int,
  viewHeight: Int,
  rootTopInWindow: Int,
  rootHeight: Int,
  imeBottomInset: Int,
): Double {
  if (viewHeight <= 0 || rootHeight <= 0 || imeBottomInset <= 0) return 0.0
  val viewBottom = viewTopInWindow.toLong() + viewHeight
  val imeTop = rootTopInWindow.toLong() + rootHeight - imeBottomInset
  return (viewBottom - imeTop).coerceIn(0L, viewHeight.toLong()).toDouble()
}

internal class TextInteractionOverlay(
  context: Context,
  private val surface: SurfaceView,
  private val inputLanguageDirectionProvider: (() -> Boolean?)? = null,
) : FrameLayout(context) {
  private sealed interface InteractionState {
    data object Idle : InteractionState

    data class Placing(
      val generation: Long,
      val pageIndex: Int,
      var directionRtl: Boolean,
      var explicitDirectionRtl: Boolean? = null,
    ) : InteractionState

    data class Editing(
      val id: String,
      val generation: Long,
      val pageIndex: Int,
      val original: TextAnnotation?,
      var anchorX: Double,
      var directionRtl: Boolean,
      val explicitDirectionRtl: Boolean?,
      var positionY: Double,
      var fontSize: Double,
      val textColor: Int,
      var automaticBaseDirectionRtl: Boolean,
      var autoRtlCharacterCount: Int = 0,
    ) : InteractionState

    data class Selected(
      val generation: Long,
      val pageIndex: Int,
      val annotation: TextAnnotation,
    ) : InteractionState

    data class Dragging(
      val generation: Long,
      val pageIndex: Int,
      val original: TextAnnotation,
      val renderLayer: TextRenderLayer,
      var position: PagePoint,
    ) : InteractionState
  }

  private sealed interface TouchTarget {
    data object OutsideEditor : TouchTarget
    data class Annotation(val generation: Long, val pageIndex: Int, val id: String) : TouchTarget
  }

  private data class PendingTouch(
    val down: MotionEvent,
    val target: TouchTarget,
    val startsSelectedDrag: Boolean = false,
    var panning: Boolean = false,
  )

  private data class PendingPlacementGesture(
    val presentation: TextPresentationSnapshot,
    val placement: InteractionState.Placing,
    val pagePoint: PagePoint,
  )

  private val density = resources.displayMetrics.density.toDouble().coerceAtLeast(0.1)
  private val outlinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = dp(1).toFloat()
    color = Color.argb(150, 100, 100, 100)
    pathEffect = DashPathEffect(floatArrayOf(dp(4).toFloat(), dp(4).toFloat()), 0f)
  }
  private val selectedOutlinePaint = Paint(outlinePaint).apply {
    strokeWidth = dp(2).toFloat()
    color = Color.argb(210, 100, 100, 100)
  }
  private val selectedBackgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.TRANSPARENT
  }
  private var pendingTouch: PendingTouch? = null
  private val annotationGesture = LongPressDragTracker(this) {
    (pendingTouch?.target as? TouchTarget.Annotation)?.let(::beginDragging)
  }
  private var interactionState: InteractionState = InteractionState.Idle
  private var editor: TextEntryView? = null
  private var defaultFontSize = defaultTextFontSize
  private var defaultTextColor = Color.BLACK
  private var editorBackgroundColor: Int? = null
  private var selectedBackgroundColor: Int? = null
  private var lastPresentation: TextPresentationSnapshot? = null
  private var pendingPlacementGesture: PendingPlacementGesture? = null
  private var consumingDismissalGesture = false
  private var settlingEditor = false
  private var suppressEditorTextChanges = false
  private var reportedMode: InteractionMode? = null
  private var requestedTextDirectionRtl: Boolean? = null

  var onInteractionModeChanged: (() -> Unit)? = null

  fun setDefaultTextColor(value: String?) {
    defaultTextColor = parseTextColor(value, Color.BLACK)
  }

  fun setOutlineColor(value: String?) {
    outlinePaint.color = textUiColor(value, Color.rgb(100, 100, 100), 150)
    refreshEditorBackground()
    invalidate()
  }

  fun setSelectedOutlineColor(value: String?) {
    selectedOutlinePaint.color = textUiColor(value, Color.rgb(100, 100, 100), 210)
    invalidate()
  }

  fun setEditorBackgroundColor(value: String?) {
    editorBackgroundColor = value?.let { parseTextColor(it, Color.TRANSPARENT) }
      ?.takeUnless { it == Color.TRANSPARENT }
    refreshEditorBackground()
  }

  private fun refreshEditorBackground() {
    val state = interactionState as? InteractionState.Editing ?: return
    editor?.background = editorBackground(editorFill(state.textColor), outlinePaint.color)
  }

  private fun editorFill(textColor: Int): Int {
    val chosen = editorBackgroundColor ?: run {
      val brightness = (299 * Color.red(textColor) + 587 * Color.green(textColor) +
        114 * Color.blue(textColor)) / 1000
      if (brightness >= 128) Color.BLACK else Color.WHITE
    }
    return Color.argb(230, Color.red(chosen), Color.green(chosen), Color.blue(chosen))
  }

  fun setSelectedBackgroundColor(value: String?) {
    selectedBackgroundColor = value?.let { textUiColor(it, Color.TRANSPARENT, 36) }
    invalidate()
  }

  init {
    setWillNotDraw(false)
    clipChildren = false
    clipToPadding = false
    isClickable = false
    isFocusable = false
    ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
      val overlap = if (editor != null && insets.isVisible(WindowInsetsCompat.Type.ime())) {
        val viewLocation = IntArray(2)
        val rootLocation = IntArray(2)
        getLocationInWindow(viewLocation)
        rootView.getLocationInWindow(rootLocation)
        localImeOverlapPx(
          viewTopInWindow = viewLocation[1],
          viewHeight = height,
          rootTopInWindow = rootLocation[1],
          rootHeight = rootView.height,
          imeBottomInset = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom,
        )
      } else {
        0.0
      }
      surface.setKeyboardOcclusion(overlap)
      insets
    }
  }

  fun setDefaultFontSize(value: Double?) {
    defaultFontSize = normalizeTextFontSize(value)
  }

  fun increaseTextSize(): Double {
    return changeEditingFont(fontSizeStep)
  }

  fun decreaseTextSize(): Double {
    return changeEditingFont(-fontSizeStep)
  }

  fun removeTextAnnotation() {
    val id = editingCommandAnnotationId() ?: throw textNotFocused()
    val presentation = surface.textPresentationSnapshot()
      ?: throw textNotFocused()
    val selectedState = interactionState as? InteractionState.Selected
    if (selectedState != null &&
      (presentation.generation != selectedState.generation ||
        presentation.pageIndex != selectedState.pageIndex)
    ) {
      clearSelection()
      throw textNotFocused()
    }
    val annotation = presentation.annotations.firstOrNull { it.id == id }
    val state = interactionState as? InteractionState.Editing
    val isEmptyDraft = state?.id == id && state.original == null
    if (annotation == null && !isEmptyDraft) {
      throw textNotFocused()
    }
    surface.withStateTransaction {
      try {
        if (annotation != null) {
          surface.removeTextAnnotation(presentation.generation, presentation.pageIndex, annotation)
        }
      } finally {
        closeEditor()
        clearSelection()
      }
    }
  }

  internal fun hasPendingPlacement(): Boolean = interactionState is InteractionState.Placing

  internal fun armPlacement(generation: Long) {
    if (interactionState is InteractionState.Placing) return
    val presentation = surface.textPresentationSnapshot() ?: throw PdfSessionException(
      "view_not_ready",
      "A laid-out PDF viewport is required before adding text",
    )
    if (presentation.generation != generation) {
      throw PdfSessionException(
        "operation_cancelled",
        "PDF view was disposed or the open was superseded",
      )
    }
    lastPresentation = presentation
    val explicitDirectionRtl = requestedTextDirectionRtl
    val directionRtl = explicitDirectionRtl ?: currentInputLanguageDirectionHint()
      ?: visibleDefaultTextDirectionIsRtl()
    transitionTo(
      InteractionState.Placing(
        generation = presentation.generation,
        pageIndex = presentation.pageIndex,
        directionRtl = directionRtl,
        explicitDirectionRtl = explicitDirectionRtl,
      ),
    )
    emitInteractionModeChanged()
    invalidate()
  }

  internal fun setTextDirection(direction: TextDirection) {
    val isRtl = when (direction) {
      TextDirection.LTR -> false
      TextDirection.RTL -> true
      TextDirection.AUTO -> null
    }
    requestedTextDirectionRtl = isRtl
    val placement = interactionState as? InteractionState.Placing ?: return
    placement.explicitDirectionRtl = isRtl
    placement.directionRtl = isRtl ?: currentInputLanguageDirectionHint()
      ?: visibleDefaultTextDirectionIsRtl()
  }

  internal fun cancelPendingPlacement() {
    if (interactionState !is InteractionState.Placing) return
    transitionTo(InteractionState.Idle)
    emitInteractionModeChanged()
    invalidate()
  }

  private fun clearPlacementForLifecycle() {
    val changed = interactionState is InteractionState.Placing || pendingPlacementGesture != null
    if (interactionState is InteractionState.Placing) transitionTo(InteractionState.Idle)
    pendingPlacementGesture = null
    if (changed) emitInteractionModeChanged()
  }

  private fun placeTextAt(
    pagePoint: PagePoint,
    presentation: TextPresentationSnapshot,
    placement: InteractionState.Placing,
  ) {
    val id = "text-${UUID.randomUUID()}"
    val isRtl = placement.explicitDirectionRtl
      ?: currentInputLanguageDirectionHint()
      ?: placement.directionRtl
    val state = InteractionState.Editing(
      id = id,
      generation = presentation.generation,
      pageIndex = presentation.pageIndex,
      original = null,
      anchorX = pagePoint.x,
      directionRtl = isRtl,
      explicitDirectionRtl = placement.explicitDirectionRtl,
      positionY = pagePoint.y,
      fontSize = defaultFontSize,
      textColor = defaultTextColor,
      automaticBaseDirectionRtl = isRtl,
    )
    transitionTo(state)
    val entry = showEditor("")
    val scale = checkNotNull(presentation.transform.uniformScale())
    val size = editorSize(entry, state, presentation)
    val horizontalPadding = entry.compoundPaddingLeft / scale
    val verticalPadding = entry.compoundPaddingTop / scale
    val snap = nearestTextSnapCandidate(
      pagePoint,
      presentation.transform,
      presentation.snapCandidates,
      dp(12).toDouble(),
    )
    val placementPoint = snap?.let {
      PagePoint(pagePoint.x, it.y - dp(3) / scale - verticalPadding)
    } ?: pagePoint
    val position = chooseTextPlacementPosition(
      placementPoint,
      size,
      presentation.page,
      horizontalPadding,
      verticalPadding,
    )
    state.anchorX = if (state.directionRtl) position.x + size.width else position.x
    state.positionY = position.y
    reconcileEditorPresentation(entry, presentation)
    val focusBounds = editorFocusBounds(entry, state, presentation)
    surface.focusTextForPlacement(
      focusBounds,
      activeEditorLineBounds(entry, state, presentation),
      dp(24).toDouble(),
      PagePoint(
        (focusBounds.left + focusBounds.right) / 2.0,
        (focusBounds.top + focusBounds.bottom) / 2.0,
      ),
    )
    syncContent()
  }

  private fun currentInputLanguageDirectionHint(): Boolean? {
    inputLanguageDirectionProvider?.let { return it() }
    val input = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
      ?: return null
    val subtype = input.currentInputMethodSubtype ?: return null
    val mode = subtype.mode
    if (!mode.isNullOrBlank() && mode != "keyboard") return null
    val language = subtype.languageTag?.takeIf { it.isNotBlank() }
    return inputLanguageDirectionHint(language)
  }

  private fun refreshEmptyEditorDirection(
    entry: TextEntryView,
    state: InteractionState.Editing,
    presentation: TextPresentationSnapshot,
  ) {
    val directionRtl = if (state.autoRtlCharacterCount > 0) true else {
      state.explicitDirectionRtl ?: currentInputLanguageDirectionHint() ?: state.directionRtl
    }
    if (state.original == null && state.explicitDirectionRtl == null &&
      state.autoRtlCharacterCount == 0
    ) state.automaticBaseDirectionRtl = directionRtl
    updateEditorDirection(entry, state, presentation, directionRtl)
  }

  private fun updateEditorDirection(
    entry: TextEntryView,
    state: InteractionState.Editing,
    presentation: TextPresentationSnapshot,
    directionRtl: Boolean,
  ) {
    if (directionRtl == state.directionRtl) return

    val currentFrame = editorBounds(entry, state, presentation)
    val frameEdge = presentation.transform.map(
      PagePoint(
        if (directionRtl) currentFrame.right else currentFrame.left,
        currentFrame.top,
      ),
    )
    state.anchorX = textEditorAnchorAfterDirectionChange(
      transform = presentation.transform,
      frameEdge = frameEdge,
      willBeRtl = directionRtl,
      paddingLeftPx = entry.compoundPaddingLeft.toDouble(),
      paddingTopPx = entry.compoundPaddingTop.toDouble(),
      paddingRightPx = entry.compoundPaddingRight.toDouble(),
    )
    state.directionRtl = directionRtl
    TextLayoutSpec.configureEditorDirection(entry, directionRtl)
  }

  fun finishForLifecycle() {
    clearPlacementForLifecycle()
    finishEditing()
    clearSelection()
  }

  fun dispose() {
    finishEditing()
    clearSelection()
    hideKeyboard()
    removeAllViews()
    lastPresentation = null
    clearPlacementForLifecycle()
    onInteractionModeChanged = null
  }

  internal fun editingAnnotationId(): String? = when (val state = interactionState) {
    is InteractionState.Editing -> state.id
    is InteractionState.Dragging -> state.original.id
    else -> null
  }

  internal fun interactionMode(): InteractionMode = when {
    interactionState is InteractionState.Placing -> InteractionMode.TEXTPLACEMENT
    interactionState is InteractionState.Editing -> InteractionMode.TEXTEDITING
    interactionState is InteractionState.Selected -> InteractionMode.TEXTSELECTED
    interactionState is InteractionState.Dragging ->
      InteractionMode.TEXTSELECTED
    surface.isEditMode -> InteractionMode.DRAW
    else -> InteractionMode.VIEW
  }

  internal fun refreshKeyboardAvoidance() {
    ViewCompat.requestApplyInsets(this)
  }

  internal fun clearSelectionForHostMode() {
    if (interactionState !is InteractionState.Idle) {
      surface.withStateTransaction {
        finishEditing()
        clearSelection()
      }
    }
  }

  fun syncContent() {
    val presentation = surface.textPresentationSnapshot()
    lastPresentation = presentation
    if (presentation == null) {
      cancelPendingTouch()
      hideKeyboard()
      editor?.let(::removeView)
      editor = null
      transitionTo(InteractionState.Idle)
      surface.setKeyboardOcclusion(0.0)
      ViewCompat.requestApplyInsets(this)
      emitInteractionModeChanged()
      return
    }

    val touchedAnnotation = pendingTouch?.target as? TouchTarget.Annotation
    if (touchedAnnotation != null &&
      (touchedAnnotation.generation != presentation.generation ||
        touchedAnnotation.pageIndex != presentation.pageIndex)
    ) cancelPendingTouch()

    when (val state = interactionState) {
      is InteractionState.Placing -> {
        if (state.generation != presentation.generation || state.pageIndex != presentation.pageIndex) {
          transitionTo(InteractionState.Idle)
        }
      }
      is InteractionState.Editing -> {
        if (state.generation != presentation.generation || state.pageIndex != presentation.pageIndex) {
          cancelEditing()
        }
      }
      is InteractionState.Dragging -> {
        if (state.generation != presentation.generation || state.pageIndex != presentation.pageIndex) {
          cancelDrag()
        }
      }
      is InteractionState.Selected -> {
        val current = presentation.annotations.firstOrNull { it.id == state.annotation.id }
        if (state.generation != presentation.generation || state.pageIndex != presentation.pageIndex ||
          current == null
        ) {
          annotationGesture.cancel()
          cancelPendingTouch()
          transitionTo(InteractionState.Idle)
        } else if (current != state.annotation) {
          transitionTo(InteractionState.Selected(state.generation, state.pageIndex, current))
        }
      }
      InteractionState.Idle -> Unit
    }
    editor?.let { entry ->
      reconcileEditorPresentation(entry, presentation)
    }
    emitInteractionModeChanged()
    surface.invalidate()
    invalidate()
  }

  fun syncTransform() {
    val transform = surface.textTransformSnapshot() ?: return
    val presentation = lastPresentation
      ?.takeIf { it.generation == transform.generation && it.pageIndex == transform.pageIndex }
      ?.copy(page = transform.page, transform = transform.transform)
      ?: return syncContent()
    lastPresentation = presentation
    editor?.let { reconcileEditorPresentation(it, presentation) }
    invalidate()
  }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    super.onMeasure(widthMeasureSpec, heightMeasureSpec)
  }

  override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
    super.onLayout(changed, left, top, right, bottom)
    lastPresentation?.let { presentation ->
      editor?.let { reconcileEditorPresentation(it, presentation) }
    }
  }

  override fun onDraw(canvas: android.graphics.Canvas) {
    super.onDraw(canvas)
    val presentation = lastPresentation ?: return
    val annotations = when (val state = interactionState) {
      is InteractionState.Dragging -> presentation.annotations.map { annotation ->
        if (annotation.id == state.original.id) annotationAt(state.original, state.position)
        else annotation
      }
      else -> presentation.annotations
    }
    if (interactionState is InteractionState.Dragging) {
      val state = interactionState as InteractionState.Dragging
      val original = state.original
      val matrix = Matrix().apply {
        setValues(floatArrayOf(
          presentation.transform.a.toFloat(),
          presentation.transform.c.toFloat(),
          presentation.transform.tx.toFloat(),
          presentation.transform.b.toFloat(),
          presentation.transform.d.toFloat(),
          presentation.transform.ty.toFloat(),
          0f,
          0f,
          1f,
        ))
      }
      canvas.save()
      canvas.concat(matrix)
      canvas.translate(
        (state.position.x - original.position.x).toFloat(),
        (state.position.y - original.position.y).toFloat(),
      )
      state.renderLayer.draw(canvas)
      canvas.restore()
    }
    val editingId = (interactionState as? InteractionState.Editing)?.id
    val selectedId = when (val state = interactionState) {
      is InteractionState.Selected -> state.annotation.id
      is InteractionState.Dragging -> state.original.id
      else -> null
    }
    val pageScale = hypot(presentation.transform.a, presentation.transform.b)
    annotations.forEach { annotation ->
      if (annotation.id == editingId) return@forEach
      val selected = annotation.id == selectedId
      val rect = textOutlineRect(annotation, presentation, pageScale)
      if (selected && selectedBackgroundColor != null) {
        selectedBackgroundPaint.color = checkNotNull(selectedBackgroundColor)
        canvas.drawRect(rect, selectedBackgroundPaint)
      }
      canvas.drawRect(rect, if (selected) selectedOutlinePaint else outlinePaint)
    }
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    pendingPlacementGesture?.let { gesture ->
      when (event.actionMasked) {
        MotionEvent.ACTION_UP -> {
          pendingPlacementGesture = null
          if (interactionState === gesture.placement) {
            transitionTo(InteractionState.Idle)
            placeTextAt(gesture.pagePoint, gesture.presentation, gesture.placement)
          }
        }
        MotionEvent.ACTION_CANCEL -> pendingPlacementGesture = null
      }
      return true
    }
    if (pendingTouch != null) return handlePendingTouch(event)
    val placement = interactionState as? InteractionState.Placing
    if (event.actionMasked == MotionEvent.ACTION_DOWN && placement != null) {
      val presentation = surface.textPresentationSnapshot()
      if (presentation == null || presentation.generation != placement.generation ||
        presentation.pageIndex != placement.pageIndex
      ) {
        transitionTo(InteractionState.Idle)
        emitInteractionModeChanged()
        return false
      }
      lastPresentation = presentation
      val mappedPoint = presentation.transform.inverse().map(
        PagePoint(event.x.toDouble(), event.y.toDouble()),
      )
      val pagePoint = PagePoint(mappedPoint.x, mappedPoint.y)
      if (!pagePoint.x.isFinite() || !pagePoint.y.isFinite() ||
        pagePoint.x < 0.0 || pagePoint.x > presentation.page.width ||
        pagePoint.y < 0.0 || pagePoint.y > presentation.page.height
      ) return false
      pendingPlacementGesture = PendingPlacementGesture(presentation, placement, pagePoint)
      return true
    }
    if (consumingDismissalGesture) {
      if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
        consumingDismissalGesture = false
      }
      return true
    }
    if (event.actionMasked == MotionEvent.ACTION_DOWN && interactionState is InteractionState.Editing) {
      val entry = editor
      if (entry != null && event.x >= entry.left && event.x <= entry.right &&
        event.y >= entry.top && event.y <= entry.bottom
      ) return false
      pendingTouch = PendingTouch(MotionEvent.obtain(event), TouchTarget.OutsideEditor)
      return true
    }
    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
      val presentation = lastPresentation
      val id = hitTest(event.x, event.y)
      if (id == null) {
        if (interactionState !is InteractionState.Idle) {
          clearSelection()
          consumingDismissalGesture = true
          return true
        }
        return false
      }
      if (presentation != null) {
        val selectedId = (interactionState as? InteractionState.Selected)?.annotation?.id
        pendingTouch = PendingTouch(
          MotionEvent.obtain(event),
          TouchTarget.Annotation(presentation.generation, presentation.pageIndex, id),
          startsSelectedDrag = selectedId == id,
        )
      }
    }
    return pendingTouch?.let { handlePendingTouch(event) } ?: false
  }

  private fun handlePendingTouch(event: MotionEvent): Boolean {
    val touch = pendingTouch ?: return false
    val annotation = touch.target as? TouchTarget.Annotation
    val action = event.actionMasked
    if (action == MotionEvent.ACTION_MOVE && !touch.panning &&
      !touch.startsSelectedDrag && !annotationGesture.dragging && kotlin.math.hypot(
        event.rawX - touch.down.rawX,
        event.rawY - touch.down.rawY,
      ) > ViewConfiguration.get(context).scaledTouchSlop
    ) {
      annotationGesture.cancel()
      surface.handleTextViewportTouch(touch.down)
      touch.panning = true
    }
    if (touch.panning) {
      surface.handleTextViewportTouch(event)
      if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
        finishPendingTouch(touch)
      }
      return true
    }
    if (annotation == null) {
      if (action == MotionEvent.ACTION_UP) {
        finishPendingTouch(touch)
        surface.withStateTransaction {
          finishEditing()
          clearSelection()
        }
      } else if (action == MotionEvent.ACTION_CANCEL) {
        finishPendingTouch(touch)
      }
      return true
    }
    val update = annotationGesture.onTouch(event, touch.startsSelectedDrag)
    update.dragDelta?.let { dragAnnotation(it.first, it.second) }
    if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
      finishPendingTouch(touch)
      when {
        update.dragReleased -> surface.withStateTransaction { commitDrag() }
        update.dragCancelled -> cancelDrag()
        update.tap -> beginEditing(annotation.id)
      }
    }
    return true
  }

  private fun finishPendingTouch(touch: PendingTouch) {
    if (pendingTouch === touch) pendingTouch = null
    touch.down.recycle()
  }

  private fun cancelPendingTouch() {
    val touch = pendingTouch ?: return
    annotationGesture.cancel()
    if (touch.panning) {
      val cancel = MotionEvent.obtain(touch.down)
      cancel.action = MotionEvent.ACTION_CANCEL
      surface.handleTextViewportTouch(cancel)
      cancel.recycle()
    }
    finishPendingTouch(touch)
  }

  private fun showEditor(value: String): TextEntryView {
    editor?.let { removeView(it) }
    val state = checkNotNull(interactionState as? InteractionState.Editing)
    val entry = TextEntryView(context).apply {
      inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
      isSingleLine = false
      setHorizontallyScrolling(false)
      background = editorBackground(editorFill(state.textColor), outlinePaint.color)
      setText(value)
      configureEditorPreservingSelection(
        this,
        displayFontSize(state.fontSize),
        state.directionRtl,
        state.textColor,
      )
      setSelection(text.length)
      addTextChangedListener(object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {
          if (count > 0 && !suppressEditorTextChanges && editor === this@apply) {
            val state = interactionState as? InteractionState.Editing ?: return
            if (state.original == null && state.explicitDirectionRtl == null) {
              state.autoRtlCharacterCount -= countStrongRtlCharacters(s!!.subSequence(start, start + count))
            }
          }
          if (!s.isNullOrEmpty() || count != 0 || after == 0 ||
            suppressEditorTextChanges || editor !== this@apply
          ) return
          val state = interactionState as? InteractionState.Editing ?: return
          lastPresentation?.let { refreshEmptyEditorDirection(this@apply, state, it) }
        }

        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
          if (count == 0 || suppressEditorTextChanges || editor !== this@apply) return
          val state = interactionState as? InteractionState.Editing ?: return
          if (state.original == null && state.explicitDirectionRtl == null) {
            state.autoRtlCharacterCount += countStrongRtlCharacters(s!!.subSequence(start, start + count))
          }
        }
        override fun afterTextChanged(s: Editable?) {
          if (!suppressEditorTextChanges && editor === this@apply) {
            val state = interactionState as? InteractionState.Editing ?: return
            if (state.original == null && state.explicitDirectionRtl == null) {
              val directionRtl = state.autoRtlCharacterCount > 0 || state.automaticBaseDirectionRtl
              lastPresentation?.let { updateEditorDirection(this@apply, state, it, directionRtl) }
            }
            if (s.isNullOrEmpty()) {
              lastPresentation?.let { refreshEmptyEditorDirection(this@apply, state, it) }
            }
            TextLayoutSpec.configureEditorDirection(this@apply, state.directionRtl)
            requestLayout()
            lastPresentation?.let { reconcileEditorPresentation(this@apply, it) }
            invalidate()
          }
        }
      })
      onKeyboardDismissed = { finishForLifecycle() }
      onFocusChangeListener = View.OnFocusChangeListener { _, hasFocus ->
        if (hasFocus && editor === this@apply) {
          val state = interactionState as? InteractionState.Editing
          val presentation = lastPresentation
          if (state != null && presentation != null && text.isNullOrEmpty()) {
            refreshEmptyEditorDirection(this@apply, state, presentation)
            TextLayoutSpec.configureEditorDirection(this@apply, state.directionRtl)
            requestLayout()
            reconcileEditorPresentation(this@apply, presentation)
          }
        } else if (!hasFocus && !settlingEditor && editor === this@apply) {
          finishForLifecycle()
        }
      }
    }
    editor = entry
    entry.onEmptySelectionChanged = {
      if (editor === entry) {
        val state = interactionState as? InteractionState.Editing
        val presentation = lastPresentation
        if (state != null && presentation != null && entry.text.isNullOrEmpty()) {
          refreshEmptyEditorDirection(entry, state, presentation)
          TextLayoutSpec.configureEditorDirection(entry, state.directionRtl)
          entry.requestLayout()
          reconcileEditorPresentation(entry, presentation)
        }
      }
    }
    entry.onCaretChanged = {
      if (editor === entry) {
        val state = interactionState as? InteractionState.Editing
        val transform = surface.textTransformSnapshot()
        val previousPresentation = lastPresentation
        if (state != null && transform != null && previousPresentation != null &&
          previousPresentation.generation == transform.generation &&
          previousPresentation.pageIndex == transform.pageIndex &&
          !surface.isTextFocusAnimating()
        ) {
          val presentation = previousPresentation.copy(
            page = transform.page,
            transform = transform.transform,
          )
          lastPresentation = presentation
          val inverse = presentation.transform.inverse()
          val topLeft = inverse.map(PagePoint(entry.left.toDouble(), entry.top.toDouble()))
          val bottomRight = inverse.map(PagePoint(entry.right.toDouble(), entry.bottom.toDouble()))
          val frame = PageRect(topLeft.x, topLeft.y, bottomRight.x, bottomRight.y)
          surface.ensureTextVisible(
            activeEditorLineBounds(entry, state, presentation, frame),
            dp(24).toDouble(),
          )
        }
      }
    }
    addView(entry, 0, FrameLayout.LayoutParams(1, 1))
    ViewCompat.requestApplyInsets(this)
    entry.requestFocus()
    entry.post {
      if (editor === entry) {
        val input = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        input.showSoftInput(entry, 0)
      }
    }
    return entry
  }

  private fun beginEditing(id: String) {
    val annotation = currentAnnotations().firstOrNull { it.id == id } ?: return
    val presentation = checkNotNull(lastPresentation)
    val state = InteractionState.Editing(
      id = annotation.id,
      generation = presentation.generation,
      pageIndex = presentation.pageIndex,
      original = annotation,
      anchorX = if (annotation.directionRtl) annotation.bounds.right else annotation.bounds.left,
      directionRtl = annotation.directionRtl,
      explicitDirectionRtl = null,
      positionY = annotation.position.y,
      fontSize = annotation.fontSize,
      textColor = annotation.textColor,
      automaticBaseDirectionRtl = annotation.directionRtl,
    )
    transitionTo(state)
    val entry = showEditor(annotation.text)
    surface.focusTextForEditing(
      editorFocusBounds(entry, state, presentation),
      activeEditorLineBounds(entry, state, presentation),
      dp(24).toDouble(),
    )
    syncContent()
  }

  private fun beginDragging(touch: TouchTarget.Annotation) {
    val presentation = lastPresentation ?: return
    if (presentation.generation != touch.generation || presentation.pageIndex != touch.pageIndex) return
    val annotation = currentAnnotations().firstOrNull { it.id == touch.id } ?: return
    val state = InteractionState.Dragging(
      generation = presentation.generation,
      pageIndex = presentation.pageIndex,
      original = annotation,
      renderLayer = TextRenderLayer.from(listOf(annotation)),
      position = annotation.position,
    )
    transitionTo(state)
    performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    surface.invalidate()
    invalidate()
  }

  private fun dragAnnotation(dx: Float, dy: Float) {
    val state = interactionState as? InteractionState.Dragging ?: return
    val presentation = lastPresentation ?: return
    val transform = presentation.transform
    val scale = transform.uniformScale() ?: return
    state.position = clampPosition(
      PagePoint(
        state.position.x + dx / scale,
        state.position.y + dy / scale,
      ),
      TextIntrinsicSize(state.original.intrinsicWidth, state.original.intrinsicHeight),
      presentation.page,
    )
    invalidate()
  }

  private fun commitDrag() {
    val state = interactionState as? InteractionState.Dragging ?: return
    val original = state.original
    if (state.position == original.position) {
      transitionTo(InteractionState.Selected(state.generation, state.pageIndex, original))
      emitInteractionModeChanged()
      surface.invalidate()
      invalidate()
      return
    }
    val position = clampPosition(
      state.position,
      TextIntrinsicSize(original.intrinsicWidth, original.intrinsicHeight),
      checkNotNull(lastPresentation).page,
    )
    val updated = annotationAt(original, position)
    transitionTo(InteractionState.Selected(state.generation, state.pageIndex, updated))
    try {
      surface.replaceTextAnnotation(state.generation, state.pageIndex, original, updated)
    } catch (error: RuntimeException) {
      transitionTo(InteractionState.Idle)
      throw error
    }
    emitInteractionModeChanged()
    invalidate()
  }

  private fun cancelDrag() {
    val state = interactionState as? InteractionState.Dragging ?: return
    annotationGesture.cancel()
    transitionTo(InteractionState.Selected(state.generation, state.pageIndex, state.original))
    emitInteractionModeChanged()
    surface.invalidate()
    invalidate()
  }

  private fun finishEditing(): TextAnnotation? {
    val state = interactionState as? InteractionState.Editing ?: return null
    cancelPendingTouch()
    val entry = editor
    if (entry == null) {
      transitionTo(InteractionState.Idle)
      emitInteractionModeChanged()
      return state.original
    }
    val text = materializedEditorText(entry)
    val original = state.original
    val finished = text.takeUnless { it.isBlank() }?.let { annotationAt(state, it, entry) }
    try {
      when (val mutation = settleTextEditing(original, finished)) {
        TextEditingMutation.NoOp -> Unit
        is TextEditingMutation.Append -> {
          surface.appendTextAnnotation(state.generation, state.pageIndex, mutation.annotation)
        }
        is TextEditingMutation.Replace -> {
          surface.replaceTextAnnotation(state.generation, state.pageIndex, mutation.before, mutation.after)
        }
        is TextEditingMutation.Remove -> {
          surface.removeTextAnnotation(state.generation, state.pageIndex, mutation.annotation)
        }
      }
    } finally {
      closeEditor()
      transitionTo(InteractionState.Idle)
      syncContent()
      emitInteractionModeChanged()
    }
    return finished
  }

  private fun cancelEditing() {
    cancelPendingTouch()
    closeEditor()
    transitionTo(InteractionState.Idle)
    emitInteractionModeChanged()
  }

  private fun closeEditor() {
    cancelPendingTouch()
    val entry = editor ?: run {
      return
    }
    settlingEditor = true
    try {
      entry.cancelCaretFollow()
      entry.onCaretChanged = null
      surface.setKeyboardOcclusion(0.0)
      hideKeyboard()
      removeView(entry)
      editor = null
      ViewCompat.requestApplyInsets(this)
    } finally {
      settlingEditor = false
    }
  }

  private fun clearSelection() {
    val hadSelection = interactionState !is InteractionState.Idle
    cancelPendingTouch()
    annotationGesture.cancel()
    if (editor != null) closeEditor()
    transitionTo(InteractionState.Idle)
    if (hadSelection) syncContent() else emitInteractionModeChanged()
  }

  private fun emitInteractionModeChanged() {
    val mode = interactionMode()
    if (reportedMode == mode) return
    reportedMode = mode
    onInteractionModeChanged?.invoke()
  }

  private fun textNotFocused(): PdfSessionException = PdfSessionException(
    "text_not_focused",
    "No text annotation is being edited",
  )

  private fun changeEditingFont(delta: Double): Double {
    when (val state = interactionState) {
      is InteractionState.Editing -> {
        val fontSize = (state.fontSize + delta)
          .coerceIn(minimumTextFontSize, maximumTextFontSize)
        if (fontSize == state.fontSize) return fontSize
        state.fontSize = fontSize
        editor?.let {
          configureEditorPreservingSelection(
            it,
            displayFontSize(fontSize),
            state.directionRtl,
            state.textColor,
          )
        }
        syncContent()
        return fontSize
      }
      is InteractionState.Selected -> {
        val presentation = surface.textPresentationSnapshot()
          ?: throw textNotFocused()
        if (presentation.generation != state.generation ||
          presentation.pageIndex != state.pageIndex
        ) {
          clearSelection()
          throw textNotFocused()
        }
        val annotation = presentation.annotations.firstOrNull { it.id == state.annotation.id }
          ?: throw textNotFocused()
        val fontSize = (annotation.fontSize + delta)
          .coerceIn(minimumTextFontSize, maximumTextFontSize)
        if (fontSize == annotation.fontSize) return fontSize
        val updated = resizedAnnotation(annotation, fontSize, presentation.page)
        transitionTo(InteractionState.Selected(state.generation, state.pageIndex, updated))
        try {
          surface.replaceTextAnnotation(state.generation, state.pageIndex, annotation, updated)
        } catch (error: RuntimeException) {
          transitionTo(state)
          throw error
        }
        invalidate()
        return fontSize
      }
      is InteractionState.Dragging -> throw textNotFocused()
      else -> throw textNotFocused()
    }
  }

  private fun annotationAt(
    state: InteractionState.Editing,
    text: String,
    entry: TextEntryView,
  ): TextAnnotation {
    val presentation = checkNotNull(lastPresentation)
    val size = editorSize(entry, state, presentation)
    val requestedPosition = PagePoint(
      if (state.directionRtl) state.anchorX - size.width else state.anchorX,
      state.positionY,
    )
    val position = clampPosition(requestedPosition, size, presentation.page)
    return TextAnnotation(
      id = state.id,
      text = text,
      bounds = PageRect(
        position.x,
        position.y,
        position.x + size.width,
        position.y + size.height,
      ),
      fontSize = state.fontSize,
      textColor = state.textColor,
      directionRtl = state.directionRtl,
    )
  }

  private fun annotationAt(annotation: TextAnnotation, position: PagePoint): TextAnnotation =
    annotation.copy(
      bounds = PageRect(
        position.x,
        position.y,
        position.x + annotation.intrinsicWidth,
        position.y + annotation.intrinsicHeight,
      ),
    )

  private fun resizedAnnotation(
    annotation: TextAnnotation,
    fontSize: Double,
    page: PdfPageDimensions,
  ): TextAnnotation {
    val size = textEditorIntrinsicSize(annotation.text, fontSize)
    val position = clampPosition(annotation.position, size, page)
    return TextAnnotation(
      id = annotation.id,
      text = annotation.text,
      bounds = PageRect(
        position.x,
        position.y,
        position.x + size.width,
        position.y + size.height,
      ),
      fontSize = fontSize,
      textColor = annotation.textColor,
      directionRtl = annotation.directionRtl,
    )
  }

  private fun currentAnnotations(): List<TextAnnotation> =
    surface.textPresentationSnapshot()?.annotations ?: emptyList()

  private fun editingCommandAnnotationId(): String? = when (val state = interactionState) {
    is InteractionState.Editing -> state.id
    is InteractionState.Selected -> state.annotation.id
    else -> null
  }

  private fun hitTest(viewX: Float, viewY: Float): String? {
    val presentation = lastPresentation ?: return null
    val pageScale = hypot(presentation.transform.a, presentation.transform.b)
    return presentation.annotations.asReversed().firstOrNull { annotation ->
      val selected = when (val state = interactionState) {
        is InteractionState.Selected -> state.annotation.id == annotation.id
        is InteractionState.Dragging -> state.original.id == annotation.id
        else -> false
      }
      val outer = textOutlineRect(annotation, presentation, pageScale)
      viewX >= outer.left && viewX <= outer.right && viewY >= outer.top && viewY <= outer.bottom
    }?.id
  }

  private fun textOutlineRect(
    annotation: TextAnnotation,
    presentation: TextPresentationSnapshot,
    pageScale: Double,
  ): RectF {
    val fontSizePx = annotation.fontSize * pageScale
    return textAnnotationOuterRect(
      annotation.bounds,
      presentation.transform,
      horizontalPaddingPx = textEditorPaddingPx(
        fontSizePx,
        textEditorHorizontalPaddingRatio,
      ).toFloat(),
      verticalPaddingPx = textEditorPaddingPx(
        fontSizePx,
        textEditorVerticalPaddingRatio,
      ).toFloat(),
    )
  }

  private fun layoutEditorFrame(
    view: View,
    bounds: PageRect,
    transform: PageTransform,
  ) {
    val topLeft = transform.map(PagePoint(bounds.left, bounds.top))
    val bottomRight = transform.map(PagePoint(bounds.right, bounds.bottom))
    val frameWidth = max(1, ceil(bottomRight.x - topLeft.x).toInt())
    val frameLeft = topLeft.x.toInt()
    val height = max(1, ceil(bottomRight.y - topLeft.y).toInt())
    val frameTop = topLeft.y.toInt()
    val params = view.layoutParams as? FrameLayout.LayoutParams
      ?: FrameLayout.LayoutParams(frameWidth, height)
    if (params.width != frameWidth || params.height != height ||
      params.leftMargin != frameLeft || params.topMargin != frameTop
    ) {
      params.width = frameWidth
      params.height = height
      params.leftMargin = frameLeft
      params.topMargin = frameTop
      view.layoutParams = params
    }
    view.measure(
      View.MeasureSpec.makeMeasureSpec(frameWidth, View.MeasureSpec.EXACTLY),
      View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY),
    )
    view.layout(frameLeft, frameTop, frameLeft + frameWidth, frameTop + height)
  }

  private fun reconcileEditorPresentation(
    entry: TextEntryView,
    presentation: TextPresentationSnapshot,
  ) {
    val state = interactionState as? InteractionState.Editing ?: return
    val scale = presentation.transform.uniformScale()
    if (scale != null) {
      val pixelSize = (state.fontSize * scale).toFloat()
      if (entry.textSize != pixelSize) {
        entry.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, pixelSize)
      }
      updateEditorPadding(entry, pixelSize.toDouble())
    }
    val bounds = editorBounds(entry, state, presentation)
    layoutEditorFrame(entry, bounds, presentation.transform)
    if (!surface.isTextFocusAnimating()) entry.scheduleCaretFollow()
  }

  /** Returns the active line's caret with visibility room on either side. */
  private fun activeEditorLineBounds(
    entry: TextEntryView,
    state: InteractionState.Editing,
    presentation: TextPresentationSnapshot,
    frame: PageRect = editorBounds(entry, state, presentation),
  ): PageRect {
    val scale = presentation.transform.uniformScale()
      ?: return frame
    val layout = entry.layout ?: return frame
    if (layout.lineCount <= 0) return frame
    val offset = entry.activeSelectionOffset.coerceIn(0, entry.text?.length ?: 0)
    val line = layout.getLineForOffset(offset)
    val caretX = frame.left +
      (
        entry.compoundPaddingLeft.toDouble() +
          layout.getPrimaryHorizontal(offset).toDouble() - entry.scrollX.toDouble()
        ) / scale
    val precedingX = if (offset > 0 && layout.getLineForOffset(offset - 1) == line) {
      frame.left +
        (
          entry.compoundPaddingLeft.toDouble() +
            layout.getPrimaryHorizontal(offset - 1).toDouble() - entry.scrollX.toDouble()
          ) / scale
    } else {
      caretX
    }
    val lineTop = (
      entry.compoundPaddingTop.toDouble() + layout.getLineTop(line) - entry.scrollY
      ).coerceAtLeast(0.0) / scale
    val lineBottom = (
      entry.compoundPaddingTop.toDouble() + layout.getLineBottom(line) - entry.scrollY
      ).toDouble() / scale
    val horizontalInset =
      (max(entry.compoundPaddingLeft, entry.compoundPaddingRight) + dp(1)) / scale
    val verticalInset =
      (max(entry.compoundPaddingTop, entry.compoundPaddingBottom) + dp(1)) / scale
    return PageRect(
      left = minOf(caretX, precedingX) - horizontalInset,
      top = frame.top + lineTop - verticalInset,
      right = maxOf(caretX, precedingX) + horizontalInset,
      bottom = frame.top + max(lineBottom, lineTop + 1.0) + verticalInset,
    )
  }

  private fun editorBounds(
    entry: TextEntryView,
    state: InteractionState.Editing,
    presentation: TextPresentationSnapshot,
  ): PageRect {
    return editorBoundsFor(
      state,
      entry.text?.toString().orEmpty(),
      entry,
      presentation,
    )
  }

  private fun editorFocusBounds(
    entry: TextEntryView,
    state: InteractionState.Editing,
    presentation: TextPresentationSnapshot,
  ): PageRect {
    val bounds = editorBounds(entry, state, presentation)
    val scale = presentation.transform.uniformScale() ?: 1.0
    val strokeInset = dp(1).toDouble() / scale
    return PageRect(
      bounds.left - strokeInset,
      bounds.top - strokeInset,
      bounds.right + strokeInset,
      bounds.bottom + strokeInset,
    )
  }

  private fun editorBounds(entry: TextEntryView, state: InteractionState.Editing): PageRect {
    return editorBounds(entry, state, checkNotNull(lastPresentation))
  }

  private fun editorBoundsFor(
    state: InteractionState.Editing,
    text: String,
    entry: TextEntryView? = null,
    presentation: TextPresentationSnapshot? = lastPresentation,
  ): PageRect {
    val size = if (entry != null && presentation != null) {
      editorSize(entry, state, presentation)
    } else {
      editorSize(text, state.fontSize, state.anchorX, state.directionRtl)
    }
    val bounds = textEditorPageBounds(state.anchorX, state.positionY, size, state.directionRtl)
    val scale = presentation?.transform?.uniformScale()
    return if (entry != null && scale != null) {
      textEditorFrameBounds(
        bounds,
        entry.compoundPaddingLeft / scale,
        entry.compoundPaddingTop / scale,
        entry.compoundPaddingRight / scale,
      )
    } else bounds
  }

  /** Measures the current post-edit text with EditText's native layout. */
  private fun editorSize(
    entry: TextEntryView,
    state: InteractionState.Editing,
    presentation: TextPresentationSnapshot,
  ): TextIntrinsicSize {
    val scale = presentation.transform.uniformScale()
      ?: return editorSize(entry.text?.toString().orEmpty(), state.fontSize, state.anchorX, state.directionRtl)
    val text = entry.text?.toString().orEmpty()
    val edgeDistance = if (state.directionRtl) state.anchorX else presentation.page.width - state.anchorX
    val paddingPx = (entry.compoundPaddingLeft + entry.compoundPaddingRight).toDouble()
    val minimumContentWidthPx = textEditorMinimumContentWidth(state.fontSize) * scale
    val anchoredEdgePaddingPx = if (state.directionRtl) {
      entry.compoundPaddingLeft.toDouble()
    } else {
      entry.compoundPaddingRight.toDouble()
    }
    val maximumContentWidthPx = (edgeDistance * scale - anchoredEdgePaddingPx).coerceAtLeast(1.0)
    val maximumWidthPx = max(1, ceil(maximumContentWidthPx + paddingPx).toInt())

    entry.measure(
      View.MeasureSpec.makeMeasureSpec(maximumWidthPx, View.MeasureSpec.AT_MOST),
      View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
    )
    val layout = entry.layout
    var requiredContentWidthPx = 0.0
    if (layout != null) {
      repeat(layout.lineCount) { line ->
        val lineWidthPx = abs(layout.getLineRight(line) - layout.getLineLeft(line)).toDouble()
        requiredContentWidthPx = max(requiredContentWidthPx, lineWidthPx)
      }
    }
    val nativeWidthPx = requiredContentWidthPx + paddingPx
    val widthPx = max(nativeWidthPx, minimumContentWidthPx + paddingPx)
      .coerceIn(1.0, maximumWidthPx.toDouble())
    entry.measure(
      View.MeasureSpec.makeMeasureSpec(ceil(widthPx).toInt(), View.MeasureSpec.EXACTLY),
      View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
    )
    val verticalPaddingPx = (entry.compoundPaddingTop + entry.compoundPaddingBottom).toDouble()
    val nativeHeightPx = max(
      entry.layout?.height?.toDouble() ?: 0.0,
      entry.measuredHeight.toDouble() - verticalPaddingPx,
    )
    return TextIntrinsicSize(
      width = max(widthPx - paddingPx, 1.0) / scale,
      height = max(nativeHeightPx, 1.0) / scale,
    )
  }

  private fun editorSize(
    text: String,
    fontSize: Double,
    anchorX: Double? = null,
    isRtl: Boolean = textIsRtl(text),
  ): TextIntrinsicSize {
    val intrinsic = textEditorIntrinsicSize(text, fontSize)
    val minimumPageSize = fontSize
    val bounded = textEditorPageBoundedSize(
      intrinsic,
      minimumPageSize,
      0.0,
      lastPresentation?.page?.width,
      anchorX,
      isRtl,
    )
    return TextLayoutSpec.measureWrapped(text, fontSize, bounded.width, isRtl)
  }

  private fun configureEditorPreservingSelection(
    entry: TextEntryView,
    fontSize: Double,
    directionRtl: Boolean,
    textColor: Int = defaultTextColor,
  ) {
    val start = entry.selectionStart.coerceAtLeast(0)
    val end = entry.selectionEnd.coerceAtLeast(0)
    TextLayoutSpec.configureEditor(
      entry,
      fontSize,
      directionRtl,
      textEditorPaddingPx(fontSize, textEditorHorizontalPaddingRatio),
      textEditorPaddingPx(fontSize, textEditorVerticalPaddingRatio),
      textColor,
    )
    if (entry.text != null) {
      entry.setSelection(
        start.coerceAtMost(entry.text.length),
        end.coerceAtMost(entry.text.length),
      )
    }
  }

  private fun materializedEditorText(entry: TextEntryView): String {
    val text = entry.text?.toString().orEmpty()
    val layout = entry.layout ?: return text
    return materializeSoftWraps(
      text = text,
      lineStarts = List(layout.lineCount) { line -> layout.getLineStart(line) },
      lineEnds = List(layout.lineCount) { line -> layout.getLineEnd(line) },
    )
  }

  private fun hideKeyboard() {
    editor?.let { entry ->
      val input = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
      input.hideSoftInputFromWindow(entry.windowToken, 0)
      entry.clearFocus()
    }
  }

  private fun clampPosition(
    position: PagePoint,
    size: TextIntrinsicSize,
    page: PdfPageDimensions,
  ): PagePoint {
    return clampTextAnnotationPosition(position, size, page)
  }

  private fun displayFontSize(fontSize: Double): Double {
    val scale = lastPresentation?.transform?.uniformScale() ?: density
    return fontSize * scale
  }

  private fun editorBackground(fill: Int, stroke: Int): GradientDrawable =
    GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      setColor(fill)
      setStroke(dp(1), stroke)
    }

  private fun updateEditorPadding(entry: TextEntryView, fontSizePx: Double) {
    val horizontal = textEditorPaddingPx(fontSizePx, textEditorHorizontalPaddingRatio)
    val vertical = textEditorPaddingPx(fontSizePx, textEditorVerticalPaddingRatio)
    if (entry.paddingLeft != horizontal || entry.paddingTop != vertical) {
      entry.setPadding(horizontal, vertical, horizontal, vertical)
    }
  }

  private fun dp(value: Int): Int = (value * density).toInt()

  private fun transitionTo(next: InteractionState) {
    interactionState = next
  }

  private class TextEntryView(context: Context) : EditText(context) {
    var onKeyboardDismissed: (() -> Unit)? = null
    var onCaretChanged: (() -> Unit)? = null
    var onEmptySelectionChanged: (() -> Unit)? = null
    var activeSelectionOffset: Int = 0
      private set
    private var caretFollowPending = false
    private var caretFollowObserver: ViewTreeObserver? = null
    private var caretFollowListener: ViewTreeObserver.OnPreDrawListener? = null
    private val caretFollowHandler = Handler(context.mainLooper)
    private val detachedCaretFollow = Runnable {
      if (layout != null && !isLayoutRequested) dispatchCaretFollow()
      else caretFollowPending = false
    }
    private var previousSelectionStart: Int? = null
    private var previousSelectionEnd: Int? = null

    fun scheduleCaretFollow() {
      if (caretFollowPending) return
      if (!isAttachedToWindow) {
        caretFollowPending = true
        caretFollowHandler.postDelayed(detachedCaretFollow, 32L)
        return
      }
      caretFollowPending = true
      val observer = viewTreeObserver
      val listener = ViewTreeObserver.OnPreDrawListener {
        if (isLayoutRequested || layout == null) return@OnPreDrawListener true
        dispatchCaretFollow()
        true
      }
      caretFollowObserver = observer
      caretFollowListener = listener
      observer.addOnPreDrawListener(listener)
      invalidate()
    }

    fun cancelCaretFollow() {
      caretFollowPending = false
      caretFollowHandler.removeCallbacks(detachedCaretFollow)
      val observer = caretFollowObserver
      val listener = caretFollowListener
      if (observer?.isAlive == true && listener != null) observer.removeOnPreDrawListener(listener)
      caretFollowObserver = null
      caretFollowListener = null
    }

    private fun dispatchCaretFollow() {
      val observer = caretFollowObserver
      val listener = caretFollowListener
      if (observer?.isAlive == true && listener != null) observer.removeOnPreDrawListener(listener)
      caretFollowObserver = null
      caretFollowListener = null
      try {
        onCaretChanged?.invoke()
      } finally {
        caretFollowPending = false
      }
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
      super.onSelectionChanged(selStart, selEnd)
      val oldStart = previousSelectionStart
      val oldEnd = previousSelectionEnd
      activeSelectionOffset = activeSelectionOffsetAfterChange(
        previousStart = oldStart,
        previousEnd = oldEnd,
        previousActive = activeSelectionOffset,
        start = selStart,
        end = selEnd,
      )
      previousSelectionStart = selStart
      previousSelectionEnd = selEnd
      if (text.isNullOrEmpty()) onEmptySelectionChanged?.invoke()
      if (onCaretChanged != null) scheduleCaretFollow()
    }

    override fun onKeyPreIme(keyCode: Int, event: KeyEvent): Boolean {
      val handled = super.onKeyPreIme(keyCode, event)
      if (keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
        onKeyboardDismissed?.invoke()
      }
      return handled
    }
  }

  private data class DragUpdate(
    val dragDelta: Pair<Float, Float>? = null,
    val dragReleased: Boolean = false,
    val dragCancelled: Boolean = false,
    val tap: Boolean = false,
  )

  private class LongPressDragTracker(
    private val host: View,
    private val onStart: () -> Unit,
  ) {
    private val handler = android.os.Handler(host.context.mainLooper)
    private val touchSlop = ViewConfiguration.get(host.context).scaledTouchSlop.toFloat()
    private var downRawX = 0f
    private var downRawY = 0f
    private var lastRawX = 0f
    private var lastRawY = 0f
    private var longPressed = false
    private var tapEligible = false
    private var startsSelectedDrag = false
    var dragging = false
      private set

    fun onTouch(event: MotionEvent, selectedDragCandidate: Boolean = false): DragUpdate = when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        downRawX = event.rawX
        downRawY = event.rawY
        lastRawX = event.rawX
        lastRawY = event.rawY
        longPressed = false
        tapEligible = true
        dragging = false
        startsSelectedDrag = selectedDragCandidate
        host.isPressed = true
        if (!startsSelectedDrag) {
          handler.postDelayed({
            if (host.isPressed && !longPressed) {
              longPressed = true
              dragging = true
              onStart()
            }
          }, longPressTimeout)
        }
        DragUpdate()
      }
      MotionEvent.ACTION_MOVE -> {
        if (!longPressed && !dragging &&
          kotlin.math.hypot(event.rawX - downRawX, event.rawY - downRawY) > touchSlop
        ) {
          tapEligible = false
          if (startsSelectedDrag) {
            dragging = true
            onStart()
          } else {
            handler.removeCallbacksAndMessages(null)
          }
        }
        if (!dragging) {
          DragUpdate()
        } else {
          val delta = Pair(event.rawX - lastRawX, event.rawY - lastRawY)
          lastRawX = event.rawX
          lastRawY = event.rawY
          DragUpdate(dragDelta = delta)
        }
      }
      MotionEvent.ACTION_UP -> finish(tap = tapEligible && !longPressed)
      MotionEvent.ACTION_CANCEL -> finish(cancelled = true)
      else -> DragUpdate()
    }

    fun cancel() {
      handler.removeCallbacksAndMessages(null)
      host.isPressed = false
      dragging = false
      longPressed = false
      tapEligible = false
      startsSelectedDrag = false
    }

    private fun finish(tap: Boolean = false, cancelled: Boolean = false): DragUpdate {
      handler.removeCallbacksAndMessages(null)
      host.isPressed = false
      val ended = dragging
      dragging = false
      tapEligible = false
      startsSelectedDrag = false
      return DragUpdate(
        dragReleased = ended && !cancelled,
        dragCancelled = ended && cancelled,
        tap = tap,
      )
    }

    private companion object {
      const val longPressTimeout = 500L
    }
  }

  private companion object {
    const val fontSizeStep = 1.0
  }
}
