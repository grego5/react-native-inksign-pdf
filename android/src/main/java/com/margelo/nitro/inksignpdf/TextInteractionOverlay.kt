package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.SpannableStringBuilder
import android.text.TextWatcher
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewTreeObserver
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.max

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
  val pageId: String,
  val page: PdfPageDimensions,
  val geometryRevision: Long,
  val transform: PageTransform,
  val annotations: List<TextAnnotation>,
  val snapCandidates: List<PdfiumHorizontalSnapCandidate> = emptyList(),
  val displayPage: PdfPageDimensions = page,
  val displayTransform: PageTransform = transform,
) {
  fun forAnnotation(annotation: TextAnnotation): TextPresentationSnapshot {
    val coordinates = PageCoordinates(displayPage)
    return copy(
      page = annotation.layoutPage ?: coordinates.rawPage,
      transform = annotation.layoutToDisplay(displayPage).then(displayTransform),
    )
  }

  fun toDisplay(bounds: PageRect): PageRect {
    val layoutToDisplay = transform.then(displayTransform.inverse())
    return textAnnotationOuterBounds(bounds, layoutToDisplay, 0.0, 0.0)
  }
}

internal data class CapturedTextPage(
  val generation: Long,
  val pageId: String,
  val dimensions: PdfPageDimensions,
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

internal fun programmaticTextFlowBounds(
  bounds: TextAnnotationBounds,
  page: PdfPageDimensions,
): PageRect {
  val right = bounds.x + bounds.width
  val bottom = bounds.y + bounds.height
  val valid = bounds.x.isFinite() && bounds.y.isFinite() &&
    bounds.width.isFinite() && bounds.height.isFinite() &&
    bounds.width > 0.0 && bounds.height > 0.0 &&
    right.isFinite() && bottom.isFinite() &&
    bounds.x >= 0.0 && bounds.y >= 0.0 &&
    right <= page.width && bottom <= page.height
  if (!valid) {
    throw PdfSessionException(
      "invalid_text_bounds",
      "Text bounds must define an ordered rectangle inside the active page",
    )
  }
  return PageRect(
    left = bounds.x,
    top = bounds.y,
    right = right,
    bottom = bottom,
  )
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
  fallbackLineHeightPx: Double = 0.0,
): PdfiumHorizontalSnapCandidate? {
  val touchY = transform.map(pagePoint).y
  return candidates.asSequence()
    .filter { pagePoint.x in it.left..it.right }
    .map { candidate ->
      val ruleY = transform.map(PagePoint(pagePoint.x, candidate.y)).y
      val distance = ruleY - touchY
      val aboveBand = maxOf(maximumDistancePx,
        candidate.labelLineHeight?.takeIf { it.isFinite() && it > 0.0 } ?: fallbackLineHeightPx)
      candidate to (abs(distance) to if (distance >= 0.0) aboveBand else maximumDistancePx)
    }
    .filter { (_, distanceAndBand) -> distanceAndBand.first <= distanceAndBand.second }
    .minByOrNull { it.second.first }
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
  val scale = checkNotNull(transform.uniformScale())
  return transform.unmap(frameEdge).x + if (willBeRtl) -paddingRightPx / scale else paddingLeftPx / scale
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
) : FrameLayout(context) {
  private sealed interface InteractionState {
    data object Idle : InteractionState

    data class Placing(
      val generation: Long,
      val pageIndex: Int,
      var directionRtl: Boolean,
      val options: TextModeOptions?,
    ) : InteractionState

    data class Editing(
      val id: Long,
      val generation: Long,
      val pageIndex: Int,
      val pageId: String,
      val original: TextAnnotation?,
      var anchorX: Double,
      var directionRtl: Boolean,
      var positionY: Double,
      var fontSize: Double,
      var textColor: Int,
      val flowBounds: PageRect? = original?.flowBounds,
      var maxLines: Int = original?.maxLines ?: 0,
      var verticalAnchor: TextVerticalAnchor = original?.verticalAnchor ?: TextVerticalAnchor.TOP,
      var alignment: TextAlignment = original?.alignment ?: TextAlignment.START,
      var directionSwitchFrame: PageRect? = null,
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
    data class Annotation(val generation: Long, val pageIndex: Int, val id: Long) : TouchTarget
  }

  private data class PendingTouch(
    val down: MotionEvent,
    val target: TouchTarget,
    val startsSelectedDrag: Boolean = false,
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
  internal var onTextSelectionChange: ((TextSelection?) -> Unit)? = null
  private var emittedSelection: TextSelection? = null
  private var editor: TextEntryView? = null
  private var defaultFontSize = defaultTextFontSize
  private var defaultTextColor = Color.BLACK
  private var editorBackgroundColor: Int? = null
  private var selectedBackgroundColor: Int? = null
  private var displayPresentation: TextPresentationSnapshot? = null
  private var lastPresentation: TextPresentationSnapshot?
    get() {
      val presentation = displayPresentation ?: return null
      val annotation = when (val state = interactionState) {
        is InteractionState.Editing -> state.original
        is InteractionState.Selected -> state.annotation
        is InteractionState.Dragging -> state.original
        else -> null
      }
      return annotation?.let(presentation::forAnnotation) ?: presentation
    }
    set(value) {
      displayPresentation = value?.copy(page = value.displayPage, transform = value.displayTransform)
    }
  private var pendingPlacementGesture: PendingPlacementGesture? = null
  private var consumingDismissalGesture = false
  private var settlingEditor = false
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

  internal fun armPlacement(generation: Long, options: TextModeOptions? = null) {
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
    val directionRtl = when (options?.direction) {
      TextDirection.LTR -> false
      TextDirection.RTL -> true
      TextDirection.AUTO -> appLayoutIsRtl()
      null -> requestedTextDirectionRtl ?: appLayoutIsRtl()
    }
    transitionTo(
      InteractionState.Placing(
        generation = presentation.generation,
        pageIndex = presentation.pageIndex,
        directionRtl = directionRtl,
        options = options,
      ),
    )
    emitInteractionModeChanged()
    invalidate()
  }

  internal fun addTextAnnotation(
    bounds: TextAnnotationBounds,
    text: String,
    options: TextAnnotationOptions?,
    requireVisibleLine: Boolean = false,
    resolvedDirectionRtl: Boolean? = null,
    capturedPage: CapturedTextPage? = null,
    targetId: Long? = null,
  ) {
    val presentation = if (capturedPage == null) {
      surface.textPresentationSnapshot() ?: throw PdfSessionException(
        "view_not_ready",
        "A PDF page must be open before adding text",
      )
    } else {
      null
    }
    val directionRtl = resolvedDirectionRtl ?: when (options?.direction) {
      TextDirection.LTR -> false
      TextDirection.RTL -> true
      TextDirection.AUTO -> appLayoutIsRtl()
      null -> requestedTextDirectionRtl ?: appLayoutIsRtl()
    }
    val page = capturedPage?.dimensions ?: checkNotNull(presentation).page
    val flowBounds = programmaticTextFlowBounds(bounds, page)
    val pageId = capturedPage?.pageId ?: checkNotNull(presentation).pageId
    val slot = targetId?.let(surface.documentCoordinator::textTarget) ?:
      surface.documentCoordinator.reserveTextTarget(
        pageId = pageId,
        sourceIdentity = null,
        fieldName = null,
        canonicalBounds = PageCoordinates(page).displayToCanonical(flowBounds),
        options = options,
      )
    val verticalAnchor = options?.verticalAnchor ?: TextVerticalAnchor.TOP
    val alignment = options?.alignment ?: TextAlignment.START
    val boundedAnnotation = TextAnnotation(
      id = slot.id,
      text = text,
      bounds = flowBounds,
      fontSize = options?.fontSize ?: defaultFontSize,
      textColor = parseTextColor(options?.color, defaultTextColor),
      directionRtl = directionRtl,
      flowBounds = flowBounds,
      maxLines = options?.maxLines?.toInt() ?: 0,
      verticalAnchor = verticalAnchor,
      alignment = alignment,
      layoutPage = page,
    )
    val annotation = boundedAnnotation.copy(bounds = TextLayoutSpec.visibleBounds(boundedAnnotation, flowBounds))
    if (requireVisibleLine && (annotation.bounds.right <= annotation.bounds.left ||
      annotation.bounds.bottom <= annotation.bounds.top)) {
      throw PdfSessionException("text_rule_not_found", "No complete text line fits beside the selected rule")
    }
    if (capturedPage != null) {
      surface.appendTextAnnotationForPage(capturedPage.generation, capturedPage.pageId, annotation)
    } else {
      checkNotNull(presentation)
      surface.appendTextAnnotation(presentation.generation, presentation.pageIndex, annotation)
    }
  }

  internal fun resolveDirection(direction: TextDirection?): Boolean = when (direction) {
    TextDirection.LTR -> false
    TextDirection.RTL -> true
    TextDirection.AUTO -> appLayoutIsRtl()
    null -> requestedTextDirectionRtl ?: appLayoutIsRtl()
  }

  internal fun setTextDirection(direction: TextDirection) {
    val isRtl = when (direction) {
      TextDirection.LTR -> false
      TextDirection.RTL -> true
      TextDirection.AUTO -> null
    }
    requestedTextDirectionRtl = isRtl
    val directionRtl = isRtl ?: appLayoutIsRtl()
    when (val state = interactionState) {
      is InteractionState.Placing -> state.directionRtl = directionRtl
      is InteractionState.Editing -> updateActiveEditorDirection(state, directionRtl)
      else -> Unit
    }
  }

  private fun updateActiveEditorDirection(
    state: InteractionState.Editing,
    directionRtl: Boolean,
  ) {
    if (state.directionRtl == directionRtl) return
    val entry = checkNotNull(editor)
    val presentation = checkNotNull(lastPresentation)
    val transform = presentation.transform
    val previousBounds = editorFramePageBounds(entry, transform)
    val frameEdge = transform.map(
      PagePoint(
        if (directionRtl) previousBounds.right else previousBounds.left,
        previousBounds.top,
      ),
    )

    state.directionRtl = directionRtl
    configureEditorPreservingSelection(
      entry,
      displayFontSize(state.fontSize),
      directionRtl,
      state.textColor,
      state.alignment,
    )
    state.anchorX = textEditorAnchorAfterDirectionChange(
      transform,
      frameEdge,
      directionRtl,
      entry.compoundPaddingLeft.toDouble(),
      entry.compoundPaddingTop.toDouble(),
      entry.compoundPaddingRight.toDouble(),
    )
    state.directionSwitchFrame = previousBounds
    reconcileEditorPresentation(entry, presentation)
  }

  private fun appLayoutIsRtl(): Boolean =
    ViewCompat.getLayoutDirection(surface) == View.LAYOUT_DIRECTION_RTL

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
    val isRtl = placement.directionRtl
    val options = placement.options
    val viewportRequest = ViewportRequestParser.parseTextMode(options)
    val verticalAnchor = options?.verticalAnchor ?: TextVerticalAnchor.TOP
    val flowBounds = if (options?.width == null || options.height == null) {
      null
    } else {
      try {
        programmaticTextFlowBounds(
          TextAnnotationBounds(
            pagePoint.x,
            pagePoint.y,
            options.width,
            options.height,
          ),
          presentation.page,
        )
      } catch (_: PdfSessionException) {
        return
      }
    }
    val pageId = surface.documentCoordinator.page(presentation.pageIndex).id
    val initialBounds = flowBounds ?: PageRect(pagePoint.x, pagePoint.y, pagePoint.x, pagePoint.y)
    val id = surface.documentCoordinator.reserveTextTarget(
      pageId, null, null, PageCoordinates(presentation.page).displayToCanonical(initialBounds), null,
    ).id
    val state = InteractionState.Editing(
      id = id,
      generation = presentation.generation,
      pageIndex = presentation.pageIndex,
      pageId = pageId,
      original = null,
      anchorX = pagePoint.x,
      directionRtl = isRtl,
      positionY = pagePoint.y,
      fontSize = defaultFontSize,
      textColor = defaultTextColor,
      flowBounds = flowBounds,
      maxLines = options?.maxLines?.toInt() ?: 0,
      verticalAnchor = verticalAnchor,
      alignment = options?.alignment ?: TextAlignment.START,
    )
    transitionTo(state)
    val entry = showEditor("")
    if (flowBounds != null) {
      reconcileEditorPresentation(entry, checkNotNull(lastPresentation))
      surface.focusTextForPlacement(
        editorFocusBounds(entry, state, presentation),
        activeEditorLineBounds(entry, state, presentation),
        dp(24).toDouble(),
        PagePoint(
          (flowBounds.left + flowBounds.right) / 2.0,
          (flowBounds.top + flowBounds.bottom) / 2.0,
        ),
        viewportRequest,
      )
      syncContent()
      return
    }
    val scale = checkNotNull(presentation.transform.uniformScale())
    val size = editorSize(entry, state, presentation)
    val horizontalPadding = entry.compoundPaddingLeft / scale
    val verticalPadding = entry.compoundPaddingTop / scale
    val snap = nearestTextSnapCandidate(
      pagePoint,
      presentation.transform,
      presentation.snapCandidates,
      dp(12).toDouble(),
      editor?.lineHeight?.toDouble()?.takeIf { it > 0.0 }
        ?: defaultFontSize * density * 1.2,
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
      viewportRequest,
    )
    syncContent()
  }

  fun finishForLifecycle() {
    cancelViewportTouch()
    clearPlacementForLifecycle()
    finishEditing()
    clearSelection()
  }

  fun cancelForDocumentReplacement() {
    cancelViewportTouch()
    clearPlacementForLifecycle()
    cancelEditing()
    clearSelection()
  }

  fun dispose() {
    cancelViewportTouch()
    finishEditing()
    clearSelection()
    hideKeyboard()
    removeAllViews()
    lastPresentation = null
    clearPlacementForLifecycle()
    onInteractionModeChanged = null
    onTextSelectionChange = null
  }

  internal fun editingAnnotationId(): Long? = when (val state = interactionState) {
    is InteractionState.Editing -> state.id
    is InteractionState.Dragging -> state.original.id
    else -> null
  }

  internal fun draftText(id: Long): String? =
    (interactionState as? InteractionState.Editing)?.takeIf { it.id == id }?.let {
      editor?.text?.toString() ?: ""
    }

  internal fun setPreparedDraftText(id: Long, value: String): Boolean {
    val state = interactionState as? InteractionState.Editing ?: return false
    if (state.id != id) return false
    val entry = editor ?: return false
    val current = materializedEditorText(entry)
    if (current == value) return true
    val fits = state.flowBounds?.let { flow ->
      TextLayoutSpec.fitsFlow(value, state.fontSize, state.textColor, flow,
        state.maxLines, state.directionRtl, state.alignment)
    } ?: TextLayoutSpec.fitsMaxLines(value, state.fontSize, state.textColor,
      state.maxLines, state.directionRtl, state.alignment)
    if (!fits) throw PdfSessionException(
      "text_does_not_fit", "The supplied value does not fit in the text target",
    )
    entry.setText(value)
    entry.setSelection(value.length)
    invalidate()
    return true
  }

  internal fun cancelPreparedDraft(id: Long): Boolean {
    when (val state = interactionState) {
      is InteractionState.Editing -> if (state.id == id) cancelEditing() else return false
      is InteractionState.Selected -> if (state.annotation.id == id) clearSelection() else return false
      is InteractionState.Dragging -> if (state.original.id == id) clearSelection() else return false
      else -> return false
    }
    return true
  }

  internal fun preparedDraftFontSize(id: Long): Double? =
    (interactionState as? InteractionState.Editing)?.takeIf { it.id == id }?.fontSize

  internal fun preparedDefaultFontSize(): Double = defaultFontSize

  internal fun setPreparedDraftOptions(id: Long, options: TextAnnotationOptions): Boolean {
    val state = interactionState as? InteractionState.Editing ?: return false
    if (state.id != id) return false
    val entry = editor ?: return false
    val directionRtl = when (options.direction) {
      TextDirection.LTR -> false
      TextDirection.RTL -> true
      TextDirection.AUTO -> appLayoutIsRtl()
      null -> state.directionRtl
    }
    state.fontSize = options.fontSize ?: state.fontSize
    state.textColor = parseTextColor(options.color, state.textColor)
    state.maxLines = options.maxLines?.toInt() ?: state.maxLines
    state.alignment = options.alignment ?: state.alignment
    state.verticalAnchor = options.verticalAnchor ?: state.verticalAnchor
    state.directionRtl = directionRtl
    configureEditorPreservingSelection(entry, displayFontSize(state.fontSize), directionRtl,
      state.textColor, state.alignment)
    invalidate()
    return true
  }

  internal fun interactionMode(): InteractionMode = when {
    interactionState is InteractionState.Placing -> InteractionMode.TEXTADD
    interactionState is InteractionState.Editing -> InteractionMode.TEXTEDIT
    interactionState is InteractionState.Selected -> InteractionMode.VIEW
    interactionState is InteractionState.Dragging -> InteractionMode.VIEW
    surface.isEditMode -> InteractionMode.INK
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
    viewportTouchPage?.let { (generation, pageIndex) ->
      if (presentation == null || presentation.generation != generation || presentation.pageIndex != pageIndex) {
        cancelViewportTouch()
      }
    }
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
      ?.copy(page = transform.page, transform = transform.transform,
        displayPage = transform.page, displayTransform = transform.transform)
      ?: return syncContent()
    lastPresentation = presentation
    editor?.let { reconcileEditorPresentation(it, checkNotNull(lastPresentation)) }
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
      val originalOrigin = original.flowBounds?.let { PagePoint(it.left, it.top) } ?: original.position
      canvas.translate(
        (state.position.x - originalOrigin.x).toFloat(),
        (state.position.y - originalOrigin.y).toFloat(),
      )
      state.renderLayer.draw(canvas, inLayoutSpace = true)
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

  private enum class TouchOwner { TEXT, VIEWPORT, DISCARD }
  private var touchOwner = TouchOwner.TEXT
  private var viewportTouchDown: MotionEvent? = null
  private var viewportTouchPage: Pair<Long, Int>? = null
  private var caretFollowPaused = false

  private fun pauseCaretFollow() {
    caretFollowPaused = true
    editor?.cancelCaretFollow()
  }

  private fun canFollowCaret(): Boolean =
    !caretFollowPaused && touchOwner == TouchOwner.TEXT && !surface.isTextFocusAnimating()

  private fun startViewportTouch(down: MotionEvent) {
    pauseCaretFollow()
    touchOwner = TouchOwner.VIEWPORT
    surface.handleViewportTouch(down)
  }

  private fun finishViewportTouch() {
    touchOwner = TouchOwner.TEXT
    viewportTouchDown?.recycle()
    viewportTouchDown = null
    viewportTouchPage = null
  }

  private fun cancelViewportTouch() {
    val down = viewportTouchDown
    val discard = touchOwner == TouchOwner.DISCARD || down != null || pendingTouch != null
    cancelPendingTouch()
    if (touchOwner == TouchOwner.VIEWPORT && down != null) {
      val cancel = MotionEvent.obtain(down)
      cancel.action = MotionEvent.ACTION_CANCEL
      surface.handleViewportTouch(cancel)
      cancel.recycle()
    }
    finishViewportTouch()
    if (discard) touchOwner = TouchOwner.DISCARD
    editor?.cancelCaretFollow()
  }

  override fun dispatchTouchEvent(event: MotionEvent): Boolean {
    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
      finishViewportTouch()
      viewportTouchDown = MotionEvent.obtain(event)
      viewportTouchPage = surface.textTransformSnapshot()?.let { it.generation to it.pageIndex }
    }
    if (touchOwner == TouchOwner.DISCARD) {
      if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
        finishViewportTouch()
      }
      return true
    }
    if (touchOwner == TouchOwner.TEXT && event.actionMasked == MotionEvent.ACTION_POINTER_DOWN &&
      interactionState !is InteractionState.Idle && viewportTouchDown != null
    ) {
      val down = checkNotNull(viewportTouchDown)
      val page = viewportTouchPage
      viewportTouchDown = null
      val cancel = MotionEvent.obtain(event)
      cancel.action = MotionEvent.ACTION_CANCEL
      super.dispatchTouchEvent(cancel)
      cancel.recycle()
      viewportTouchDown = down
      viewportTouchPage = page
      startViewportTouch(down)
    }
    val handled = if (touchOwner == TouchOwner.VIEWPORT) {
      surface.handleViewportTouch(event)
      true
    } else super.dispatchTouchEvent(event)
    if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
      finishViewportTouch()
    }
    return handled
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    if (event.actionMasked == MotionEvent.ACTION_DOWN && viewportTouchDown == null) {
      finishViewportTouch()
      viewportTouchDown = MotionEvent.obtain(event)
      viewportTouchPage = surface.textTransformSnapshot()?.let { it.generation to it.pageIndex }
    }
    val handled = when (touchOwner) {
      TouchOwner.VIEWPORT -> { surface.handleViewportTouch(event); true }
      TouchOwner.DISCARD -> true
      TouchOwner.TEXT -> handleTextTouch(event)
    }
    if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
      finishViewportTouch()
    }
    return handled
  }

  private fun handleTextTouch(event: MotionEvent): Boolean {
    pendingPlacementGesture?.let { gesture ->
      val down = viewportTouchDown
      if (event.actionMasked == MotionEvent.ACTION_MOVE && down != null &&
        kotlin.math.hypot(event.x - down.x, event.y - down.y) > ViewConfiguration.get(context).scaledTouchSlop
      ) {
        pendingPlacementGesture = null
        startViewportTouch(down)
        surface.handleViewportTouch(event)
        return true
      }
      when (event.actionMasked) {
        MotionEvent.ACTION_UP -> {
          pendingPlacementGesture = null
          if (interactionState === gesture.placement) {
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
    if (action == MotionEvent.ACTION_MOVE &&
      !touch.startsSelectedDrag && !annotationGesture.dragging && kotlin.math.hypot(
        event.rawX - touch.down.rawX,
        event.rawY - touch.down.rawY,
      ) > ViewConfiguration.get(context).scaledTouchSlop
    ) {
      annotationGesture.cancel()
      startViewportTouch(touch.down)
      finishPendingTouch(touch)
      surface.handleViewportTouch(event)
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
    finishPendingTouch(touch)
  }

  private fun showEditor(value: String): TextEntryView {
    caretFollowPaused = false
    editor?.let { removeView(it) }
    val state = checkNotNull(interactionState as? InteractionState.Editing)
    val entry = TextEntryView(context).apply {
      keepPrefixAtTop = state.flowBounds != null
      preserveComposingRangeForFilter = state.flowBounds != null || state.maxLines > 0
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
        state.alignment,
      )
      setSelection(text.length)
      if (state.flowBounds != null || state.maxLines > 0) {
        filters = filters + InputFilter { source, start, end, dest, dstart, dend ->
          val currentState = interactionState as? InteractionState.Editing
          val flowBounds = currentState?.flowBounds
          if (start >= end || currentState == null ||
            (flowBounds == null && currentState.maxLines <= 0)
          ) {
            null
          } else {
            val prospectiveText = buildString(dest.length - (dend - dstart) + (end - start)) {
              append(dest, 0, dstart)
              append(source, start, end)
              append(dest, dend, dest.length)
            }
            val fits = if (flowBounds != null) {
              TextLayoutSpec.fitsFlow(
                text = prospectiveText,
                fontSize = currentState.fontSize,
                textColor = currentState.textColor,
                flowBounds = flowBounds,
                maxLines = currentState.maxLines,
                baseDirectionRtl = currentState.directionRtl,
                alignment = currentState.alignment,
              )
            } else {
              TextLayoutSpec.fitsMaxLines(
                text = prospectiveText,
                fontSize = currentState.fontSize,
                textColor = currentState.textColor,
                maxLines = currentState.maxLines,
                baseDirectionRtl = currentState.directionRtl,
                alignment = currentState.alignment,
              )
            }
            if (fits) {
              null
            } else {
              val composingReplacement = this@apply.pendingComposingReplacement
              if (composingReplacement != null &&
                composingReplacement.start == dstart && composingReplacement.end == dend
              ) {
                if (end - start < composingReplacement.end - composingReplacement.start) {
                  null
                } else {
                  composingReplacement.text
                }
              } else {
                ""
              }
            }
          }
        }
      }
      addTextChangedListener(object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit

        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit

        override fun afterTextChanged(s: Editable?) {
          if (editor !== this@apply) return
          caretFollowPaused = false
          val currentState = interactionState as? InteractionState.Editing
          currentState?.directionSwitchFrame = null
          requestLayout()
          lastPresentation?.let { reconcileEditorPresentation(this@apply, it) }
          invalidate()
        }
      })
      onKeyboardDismissed = { finishForLifecycle() }
      onFocusChangeListener = View.OnFocusChangeListener { _, hasFocus ->
        if (!hasFocus && !settlingEditor && editor === this@apply) {
          finishForLifecycle()
        }
      }
    }
    editor = entry
    entry.onCaretChanged = {
      if (editor === entry) {
        val state = interactionState as? InteractionState.Editing
        val transform = surface.textTransformSnapshot()
        val previousPresentation = lastPresentation
        if (state != null && transform != null && previousPresentation != null &&
          previousPresentation.generation == transform.generation &&
          previousPresentation.pageIndex == transform.pageIndex &&
          canFollowCaret()
        ) {
          val presentation = previousPresentation.copy(
            page = transform.page,
            transform = transform.transform,
            displayPage = transform.page,
            displayTransform = transform.transform,
          )
          lastPresentation = presentation
          val layoutPresentation = checkNotNull(lastPresentation)
          val frame = editorFramePageBounds(entry, layoutPresentation.transform)
          surface.ensureTextVisible(
            layoutPresentation.toDisplay(activeEditorLineBounds(entry, state, layoutPresentation, frame)),
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

  private fun beginEditing(id: Long) {
    val annotation = currentAnnotations().firstOrNull { it.id == id } ?: return
    val presentation = checkNotNull(lastPresentation).forAnnotation(annotation)
    val state = InteractionState.Editing(
      id = annotation.id,
      generation = presentation.generation,
      pageIndex = presentation.pageIndex,
      pageId = presentation.pageId,
      original = annotation,
      anchorX = if (annotation.directionRtl) {
        (annotation.flowBounds ?: annotation.bounds).right
      } else {
        (annotation.flowBounds ?: annotation.bounds).left
      },
      directionRtl = annotation.directionRtl,
      positionY = when (annotation.verticalAnchor) {
        TextVerticalAnchor.TOP -> (annotation.flowBounds ?: annotation.bounds).top
        TextVerticalAnchor.BOTTOM -> (annotation.flowBounds ?: annotation.bounds).bottom
      },
      fontSize = annotation.fontSize,
      textColor = annotation.textColor,
      flowBounds = annotation.flowBounds,
      maxLines = annotation.maxLines,
      verticalAnchor = annotation.verticalAnchor,
      alignment = annotation.alignment,
    )
    transitionTo(state)
    val entry = showEditor(annotation.text)
    surface.focusTextForEditing(
      presentation.toDisplay(editorFocusBounds(entry, state, presentation)),
      presentation.toDisplay(activeEditorLineBounds(entry, state, presentation)),
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
      position = annotation.flowBounds?.let { PagePoint(it.left, it.top) } ?: annotation.position,
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
    val inverse = transform.inverse()
    val origin = inverse.map(PagePoint(0.0, 0.0))
    val delta = inverse.map(PagePoint(dx.toDouble(), dy.toDouble()))
    val flowBounds = state.original.flowBounds
    state.position = clampPosition(
      PagePoint(
        state.position.x + delta.x - origin.x,
        state.position.y + delta.y - origin.y,
      ),
      flowBounds?.let {
        TextIntrinsicSize(it.right - it.left, it.bottom - it.top)
      } ?: TextIntrinsicSize(state.original.intrinsicWidth, state.original.intrinsicHeight),
      presentation.page,
    )
    invalidate()
  }

  private fun commitDrag() {
    val state = interactionState as? InteractionState.Dragging ?: return
    val original = state.original
    val originalOrigin = original.flowBounds?.let { PagePoint(it.left, it.top) } ?: original.position
    if (state.position == originalOrigin) {
      transitionTo(InteractionState.Selected(state.generation, state.pageIndex, original))
      emitInteractionModeChanged()
      surface.invalidate()
      invalidate()
      return
    }
    val flowBounds = original.flowBounds
    val position = clampPosition(
      state.position,
      flowBounds?.let {
        TextIntrinsicSize(it.right - it.left, it.bottom - it.top)
      } ?: TextIntrinsicSize(original.intrinsicWidth, original.intrinsicHeight),
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
        state.directionSwitchFrame = null
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
        val updated = resizedAnnotation(annotation, fontSize, presentation.forAnnotation(annotation).page)
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
    val flowBounds = state.flowBounds
    val unboundedSize = if (flowBounds == null) {
      editorSize(entry, state, presentation)
    } else {
      null
    }
    val position = if (unboundedSize != null) {
      val requestedPosition = PagePoint(
        if (state.directionRtl) state.anchorX - unboundedSize.width else state.anchorX,
        state.positionY,
      )
      clampPosition(requestedPosition, unboundedSize, presentation.page)
    } else {
      PagePoint(checkNotNull(flowBounds).left, flowBounds.top)
    }
    val bounds = if (unboundedSize != null) {
      PageRect(
        position.x,
        position.y,
        position.x + unboundedSize.width,
        position.y + unboundedSize.height,
      )
    } else {
      checkNotNull(flowBounds)
    }
    val updated = TextAnnotation(
      id = state.id,
      text = text,
      bounds = bounds,
      fontSize = state.fontSize,
      textColor = state.textColor,
      directionRtl = state.directionRtl,
      flowBounds = flowBounds,
      maxLines = state.maxLines,
      verticalAnchor = state.verticalAnchor,
      alignment = state.alignment,
      layoutPage = state.original?.layoutPage ?: if (state.original == null) presentation.page else null,
    )
    return if (flowBounds == null) updated else updated.copy(
      bounds = TextLayoutSpec.visibleBounds(updated, flowBounds),
    )
  }

  private fun annotationAt(annotation: TextAnnotation, position: PagePoint): TextAnnotation {
    val origin = annotation.flowBounds?.let { PagePoint(it.left, it.top) } ?: annotation.position
    val dx = position.x - origin.x
    val dy = position.y - origin.y
    val bounds = PageRect(
      annotation.bounds.left + dx,
      annotation.bounds.top + dy,
      annotation.bounds.right + dx,
      annotation.bounds.bottom + dy,
    )
    val flowBounds = annotation.flowBounds?.let {
      PageRect(it.left + dx, it.top + dy, it.right + dx, it.bottom + dy)
    }
    return annotation.copy(bounds = bounds, flowBounds = flowBounds)
  }

  private fun resizedAnnotation(
    annotation: TextAnnotation,
    fontSize: Double,
    page: PdfPageDimensions,
  ): TextAnnotation {
    val size = textEditorIntrinsicSize(annotation.text, fontSize)
    val position = clampPosition(annotation.position, size, page)
    val flowBounds = annotation.flowBounds
    val updated = TextAnnotation(
      id = annotation.id,
      text = annotation.text,
      bounds = flowBounds ?: PageRect(position.x, position.y, position.x + size.width, position.y + size.height),
      fontSize = fontSize,
      layoutPage = annotation.layoutPage,
      textColor = annotation.textColor,
      directionRtl = annotation.directionRtl,
      flowBounds = flowBounds,
      maxLines = annotation.maxLines,
      verticalAnchor = annotation.verticalAnchor,
      alignment = annotation.alignment,
    )
    return if (flowBounds == null) updated else updated.copy(
      bounds = TextLayoutSpec.visibleBounds(updated, flowBounds),
    )
  }

  private fun currentAnnotations(): List<TextAnnotation> =
    surface.textPresentationSnapshot()?.annotations ?: emptyList()

  private fun editingCommandAnnotationId(): Long? = when (val state = interactionState) {
    is InteractionState.Editing -> state.id
    is InteractionState.Selected -> state.annotation.id
    else -> null
  }

  private fun hitTest(viewX: Float, viewY: Float): Long? {
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
      presentation.forAnnotation(annotation).transform,
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
    val scale = checkNotNull(transform.uniformScale())
    val frameWidth = max(1, ceil((bounds.right - bounds.left) * scale).toInt())
    val frameLeft = topLeft.x.toInt()
    val height = max(1, ceil((bounds.bottom - bounds.top) * scale).toInt())
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
    view.pivotX = 0f
    view.pivotY = 0f
    view.rotation = Math.toDegrees(kotlin.math.atan2(transform.b, transform.a)).toFloat()
  }

  private fun reconcileEditorPresentation(
    entry: TextEntryView,
    currentPresentation: TextPresentationSnapshot,
  ) {
    val state = interactionState as? InteractionState.Editing ?: return
    val presentation = state.original?.let(currentPresentation::forAnnotation) ?: currentPresentation
    val scale = presentation.transform.uniformScale()
    if (scale != null) {
      val pixelSize = (state.fontSize * scale).toFloat()
      if (entry.textSize != pixelSize) {
        entry.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, pixelSize)
      }
      updateEditorPadding(entry, pixelSize.toDouble(), state.flowBounds != null)
    }
    entry.keepPrefixAtTop = state.flowBounds != null
    val bounds = editorBounds(entry, state, presentation)
    layoutEditorFrame(entry, bounds, presentation.transform)
    if (canFollowCaret()) entry.scheduleCaretFollow()
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

  private fun editorFramePageBounds(entry: TextEntryView, transform: PageTransform): PageRect {
    val inverse = transform.inverse()
    val points = floatArrayOf(0f, 0f, entry.width.toFloat(), 0f,
      0f, entry.height.toFloat(), entry.width.toFloat(), entry.height.toFloat())
    entry.matrix.mapPoints(points)
    val corners = (0 until 4).map { index ->
      inverse.map(PagePoint(points[index * 2] + entry.left.toDouble(),
        points[index * 2 + 1] + entry.top.toDouble()))
    }
    return PageRect(
      left = corners.minOf { it.x },
      top = corners.minOf { it.y },
      right = corners.maxOf { it.x },
      bottom = corners.maxOf { it.y },
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
    state.directionSwitchFrame?.let { return it }
    state.flowBounds?.let { flowBounds ->
      val layout = TextLayoutSpec.createLayout(
        text = text,
        fontSize = state.fontSize,
        textColor = state.textColor,
        layoutWidth = flowBounds.right - flowBounds.left,
        baseDirectionRtl = state.directionRtl,
      )
      val selection = TextLayoutSpec.selectVisibleLines(
        layout,
        flowBounds,
        state.maxLines,
        state.verticalAnchor,
      )
      val top = flowBounds.top + selection.topOffset
      return PageRect(flowBounds.left, top, flowBounds.right, top + selection.height)
    }
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
    isRtl: Boolean,
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
    alignment: TextAlignment = (interactionState as? InteractionState.Editing)?.alignment
      ?: TextAlignment.START,
  ) {
    val start = entry.selectionStart.coerceAtLeast(0)
    val end = entry.selectionEnd.coerceAtLeast(0)
    val constrainedFlow = (interactionState as? InteractionState.Editing)?.flowBounds != null
    TextLayoutSpec.configureEditor(
      entry,
      fontSize,
      directionRtl,
      if (constrainedFlow) 0 else textEditorPaddingPx(fontSize, textEditorHorizontalPaddingRatio),
      if (constrainedFlow) 0 else textEditorPaddingPx(fontSize, textEditorVerticalPaddingRatio),
      textColor,
      alignment,
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

  private fun updateEditorPadding(entry: TextEntryView, fontSizePx: Double, constrainedFlow: Boolean) {
    val horizontal = if (constrainedFlow) 0 else textEditorPaddingPx(fontSizePx, textEditorHorizontalPaddingRatio)
    val vertical = if (constrainedFlow) 0 else textEditorPaddingPx(fontSizePx, textEditorVerticalPaddingRatio)
    if (entry.paddingLeft != horizontal || entry.paddingTop != vertical) {
      entry.setPadding(horizontal, vertical, horizontal, vertical)
    }
  }

  private fun dp(value: Int): Int = (value * density).toInt()

  private fun transitionTo(next: InteractionState) {
    interactionState = next
    val selection = selectedText()
    if (selection != emittedSelection) {
      emittedSelection = selection
      onTextSelectionChange?.invoke(selection)
    }
  }

  internal fun selectedText(): TextSelection? = when (val state = interactionState) {
    is InteractionState.Editing -> TextSelection(state.id.toDouble(), state.pageId)
    is InteractionState.Selected -> TextSelection(
      state.annotation.id.toDouble(), surface.documentCoordinator.page(state.pageIndex).id,
    )
    is InteractionState.Dragging -> TextSelection(
      state.original.id.toDouble(), surface.documentCoordinator.page(state.pageIndex).id,
    )
    else -> null
  }

  private class TextEntryView(context: Context) : EditText(context) {
    data class PendingComposingReplacement(
      val start: Int,
      val end: Int,
      val text: CharSequence,
    )

    var onKeyboardDismissed: (() -> Unit)? = null
    var onCaretChanged: (() -> Unit)? = null
    var keepPrefixAtTop = false
    var preserveComposingRangeForFilter = false
    var pendingComposingReplacement: PendingComposingReplacement? = null
      private set
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

    override fun scrollTo(x: Int, y: Int) {
      super.scrollTo(x, if (keepPrefixAtTop) 0 else y)
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
      val target = super.onCreateInputConnection(outAttrs) ?: return null
      if (!preserveComposingRangeForFilter) return target
      return object : InputConnectionWrapper(target, false) {
        override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean {
          val previous = pendingComposingReplacement
          pendingComposingReplacement = capturePendingComposingReplacement()
          return try {
            super.setComposingText(text, newCursorPosition)
          } finally {
            pendingComposingReplacement = previous
          }
        }

        override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
          val previous = pendingComposingReplacement
          pendingComposingReplacement = capturePendingComposingReplacement()
          return try {
            super.commitText(text, newCursorPosition)
          } finally {
            pendingComposingReplacement = previous
          }
        }
      }
    }

    private fun capturePendingComposingReplacement(): PendingComposingReplacement? {
      val content = text
      val composingStart = BaseInputConnection.getComposingSpanStart(content)
      val composingEnd = BaseInputConnection.getComposingSpanEnd(content)
      if (composingStart < 0 || composingEnd <= composingStart) return null
      val composingText = SpannableStringBuilder(
        content.subSequence(composingStart, composingEnd),
      )
      BaseInputConnection.setComposingSpans(composingText)
      return PendingComposingReplacement(
        start = composingStart,
        end = composingEnd,
        text = composingText,
      )
    }

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
