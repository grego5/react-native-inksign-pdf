package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.GestureDetector
import android.view.MotionEvent
import android.widget.FrameLayout
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.Promise
import com.margelo.nitro.core.NullType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.util.IdentityHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Native PDF/signature view implementation for the generated Nitro spec. */
@DoNotStrip
class HybridInkSignView internal constructor(
    private val context: Context,
    sessionWorker: PdfSessionWorker = PdfSessionWorker(),
) : HybridInkSignViewSpec() {
  internal val core = DocumentCore(context, sessionWorker, recordHistory = true, exportOwnership = ExportOwnership.DOCUMENT)
  private val artifactPolicy get() = core.artifacts
  private val pageInputCoordinator = PageInputCoordinator(context, artifactPolicy)
  private val container: FrameLayout = object : FrameLayout(context) {
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
      if (event.actionMasked == MotionEvent.ACTION_DOWN) coordinateTouchActive = isPickingPageCoords
      if (!coordinateTouchActive) return super.dispatchTouchEvent(event)
      // The whole stream stays with the picker, including cancellation or resolution at UP.
      surface.handleViewportTouch(event)
      coordinateTapDetector.onTouchEvent(event)
      if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
        coordinateTouchActive = false
      }
      return true
    }
  }
  internal val coordinator get() = core.coordinator
  private val inkEngine = InkEngine()
  private val lowLatencyPresenter = LowLatencyInkPresenter(
    context,
    mainView = container,
  )
  private val traceRecorder = createStrokeTraceRecorder()
  private val surface = SurfaceView(
    context,
    inkEngine,
    traceRecorder,
    lowLatencyInk = lowLatencyPresenter,
    documentCoordinator = coordinator,
  )
  private val textOverlay = TextInteractionOverlay(context, surface, core.fonts)
  private val mainHandler = Handler(Looper.getMainLooper())
  @Volatile private var viewportRequestID = 0L
  private var pageNavigationRequestID = 0L
  @Volatile private var disposed = false
  private var currentModeSession: ModeSessionToken? = null
  private var openPresentation: PreparedDocumentPresentation? = null
  private val documentSubscription = core.observe(::documentChanged)
  private data class CoordinateTarget(val generation: Long, val pageId: String, val geometryRevision: Long)
  private data class CoordinateRequest(val promise: Promise<PageCoords>, val session: ModeSessionToken? = null,
                                       var target: CoordinateTarget? = null)
  private var pendingPageCoords: CoordinateRequest? = null
  private val isPickingPageCoords: Boolean get() = pendingPageCoords?.target != null
  private var coordinateTouchActive = false
  private val coordinateTapDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
    override fun onDown(event: MotionEvent): Boolean = true
    override fun onSingleTapUp(event: MotionEvent): Boolean {
      val pending = pendingPageCoords ?: return false
      val target = pending.target ?: return false
      if (!coordinateTargetIsCurrent(target)) {
        cancelCoordinateRequest()
        return false
      }
      val coordinates = surface.pageCoordinatesAt(event.x.toDouble(), event.y.toDouble()) ?: return false
      pendingPageCoords = null
      surface.setCoordinatePicking(false)
      restoreCoordinateMode(pending)
      emitState()
      if (!coordinateTargetIsCurrent(target) || (pending.session != null && !modeSessionIsCurrent(pending.session))) {
        pending.promise.reject(operationCancelled())
        return true
      }
      pending.promise.resolve(coordinates)
      return true
    }
  })
  private var editMode = false
  private data class PendingPromise(
    val presentation: Boolean,
    val modeSession: ModeSessionToken?,
    var job: Job? = null,
    var started: Boolean = false,
  )
  private val pendingPromises = IdentityHashMap<Promise<*>, PendingPromise>()

  override val view: View
    get() = container

  override var androidFallbackFont: AndroidFallbackFont? = null
  override var strokeColor: String? = null
    set(value) {
      field = value
      updatePenConfiguration()
    }
  override var defaultTextFontSize: Double? = null
    set(value) {
      field = value
      textOverlay.setDefaultFontSize(value)
      core.text.defaultFontSize = normalizeTextFontSize(value)
    }
  override var defaultTextColor: String? = null
    set(value) {
      field = value
      textOverlay.setDefaultTextColor(value)
      core.text.defaultTextColor = parseTextColor(value, Color.BLACK)
    }
  override var outlineColor: String? = null
    set(value) {
      field = value
      textOverlay.setOutlineColor(value)
    }
  override var selectedOutlineColor: String? = null
    set(value) {
      field = value
      textOverlay.setSelectedOutlineColor(value)
    }
  override var editorBackgroundColor: String? = null
    set(value) {
      field = value
      textOverlay.setEditorBackgroundColor(value)
    }
  override var selectedBackgroundColor: String? = null
    set(value) {
      field = value
      textOverlay.setSelectedBackgroundColor(value)
    }
  override var strokeMinWidth: Double? = null
    set(value) {
      field = value
      updatePenConfiguration()
    }
  override var strokeMaxWidth: Double? = null
    set(value) {
      field = value
      updatePenConfiguration()
    }
  override var strokeSmoothing: Double? = null
    set(value) {
      field = value
      updatePenConfiguration()
    }
  override var doubleTap: DoubleTapOptions? = null
    set(value) {
      field = value
      surface.setDoubleTapConfiguration(value)
    }
  override var keyboardAvoidanceEnabled: Boolean? = null
    set(value) {
      field = value
      surface.setKeyboardAvoidanceEnabled(value != false)
      textOverlay.refreshKeyboardAvoidance()
    }
  override var pagerDirection: PagerDirection? = null
    set(value) {
      field = value
      surface.setPagerDirection(value)
    }
  override var onStateChange: ((ViewerState) -> Unit)? = null
    set(value) {
      field = value
      lastPublicState = null
      runOnMainSync { emitState() }
    }
  override var onPageChange: ((PageInfo) -> Unit)? = null
  override var onZoomChange: ((Double) -> Unit)? = null
  override var onTextSelectionChange: ((Variant_NullType_TextSelection?) -> Unit)? = null
    set(value) {
      field = value
    }
  init {
    textOverlay.onTextSelectionChange = { selection ->
      onTextSelectionChange?.invoke(
        if (selection == null) Variant_NullType_TextSelection.create(NullType.NULL)
        else Variant_NullType_TextSelection.create(selection),
      )
    }
    container.setBackgroundColor(Color.TRANSPARENT)
    container.addView(
      surface,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    container.addView(
      lowLatencyPresenter.view,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    container.addView(
      textOverlay,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    container.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
      override fun onViewAttachedToWindow(view: View) {
        lowLatencyPresenter.synchronizeLifecycleFromFramework()
      }

      override fun onViewDetachedFromWindow(view: View) {
        finishInteractionForLifecycle()
        lowLatencyPresenter.synchronizeLifecycleFromFramework()
      }
    })
    lowLatencyPresenter.synchronizeLifecycleFromFramework()
    updatePenConfiguration()
    surface.textAnnotationBeingEdited = textOverlay::editingAnnotationId
    surface.onTextContentChanged = { textOverlay.syncContent() }
    surface.onTextTransformChanged = { textOverlay.syncTransform() }
    surface.onModeChanged = {
      textOverlay.cancelPendingPlacement()
      if (surface.isEditMode) textOverlay.clearSelectionForHostMode()
    }
    surface.onWindowFocusLost = textOverlay::finishForLifecycle
    textOverlay.onInteractionModeChanged = {
      if (!surface.isOpenHandoffInProgress) emitState()
    }
    textOverlay.setDefaultFontSize(defaultTextFontSize)
    surface.onStateChange = { state ->
      if (!disposed && !surface.isOpenHandoffInProgress) {
        lastInkState = state
        emitState()
      }
    }
    surface.onPageChange = { page ->
      pendingPageCoords?.target?.let { if (!coordinateTargetIsCurrent(it)) cancelCoordinateRequest() }
      if (!disposed && !surface.isOpenHandoffInProgress) onPageChange?.invoke(toPublicPageInfo(page))
    }
    surface.onZoomChange = { zoom -> if (!disposed) onZoomChange?.invoke(zoom) }
  }

  private var documentId: String? = null
  private var loadError: String? = null

  override fun open(path: String, options: ViewportOptions?): Promise<PageInfo> {
    cancelPresentationRequests()
    return launchPromise {
      var pendingOpen: MutableDocumentCoordinator.PendingOpen? = null
      loadError = null
      emitState()
      try {
        val viewport = ViewportRequestParser.parseOpen(options)
        logFallbackFontSnapshot(androidFallbackFont)
        val pending = core.prepareOpen(path, DocumentOpenOptions(null, null, null, androidFallbackFont))
        pendingOpen = pending
        try {
          openPresentation = core.awaitOpen(pending) {
            val size = surface.awaitUsableViewportSize()
            surface.prepareDocumentPresentation(pending.info, viewport, size)
          }
          surface.beginOpenHandoff()
          core.commitOpen(pending)
        } finally { core.finishOpen(pending) }
        toPublicPageInfo(surface.currentPageInfo())
      } catch (failure: Throwable) {
        if (pendingOpen?.published != true) surface.abortOpenHandoff()
        if (!disposed && failure !is kotlinx.coroutines.CancellationException &&
          (failure as? PdfSessionException)?.code != "operation_cancelled") {
          loadError = failure.message ?: "Unable to open PDF"
          emitState()
        }
        throw failure
      } finally { openPresentation = null }
    }
  }

  override fun close(cancelPending: Boolean?): Promise<Unit> {
    cancelPresentationRequests()
    if (cancelPending == true) {
      val requests = synchronized(this) { pendingPromises.entries.map { it.key to it.value.job } }
      requests.forEach { (promise, job) -> rejectPromise(promise, operationCancelled()); job?.cancel() }
      return try { core.clearImmediately().asNitroPromise() }
      catch (error: Throwable) { Promise<Unit>().also { it.reject(error) } }
    }
    return launchPromise { core.clearDocument() }
  }

  private fun documentChanged(change: DocumentChange) {
    when (change) {
      DocumentChange.Opening, DocumentChange.Cleared -> {
        pageInputCoordinator.cancelPending()
        viewportRequestID += 1L
        pageNavigationRequestID += 1L
        textOverlay.cancelForDocumentReplacement()
        documentId = null
        surface.clearDocument()
        editMode = false
        lastInkState = InkState(false, false, false)
        emitState()
      }
      DocumentChange.Opened -> {
        documentId = java.util.UUID.randomUUID().toString()
        surface.publishOpenDocumentPresentation(checkNotNull(openPresentation))
        editMode = false
        lastInkState = InkState(false, false, false)
        surface.notifyPublishedOpenDocumentPresentation()
        emitState()
      }
      DocumentChange.WillChangePages -> prepareStructuralMutation(creatingDocument = !coordinator.hasDocument)
      DocumentChange.Pages -> {
        viewportRequestID += 1L
        surface.installStructuralPresentation()
      }
      is DocumentChange.Text -> surface.refreshCommittedText(change.pageId)
    }
  }

  private fun logFallbackFontSnapshot(fallbackFontSnapshot: AndroidFallbackFont?) {
    if (BuildConfig.DEBUG) {
      Log.i(
        "InkSignPdf",
        "PDFium component fallback snapshot configured=${fallbackFontSnapshot != null} " +
          "uri=${fallbackFontSnapshot?.uri ?: ""}",
      )
    }
  }

  override fun addPages(options: AddPagesOptions?): Promise<AddPagesResult> = launchPromise {
    val sources = options?.sources ?: pageInputCoordinator.pickSources(options?.type)
    val explicit = AddPagesOptions(options?.type, sources, options?.imagePageSize,
      options?.targetDpi, options?.jpegQuality, options?.activePage)
    val dimensions = options?.imagePageSize?.let { PdfPageDimensions(it.width, it.height) }
      ?: coordinator.pages.getOrNull(coordinator.activePageIndex)?.dimensions ?: PdfPageDimensions(595.28, 841.89)
    val added = core.addPages(explicit, dimensions, androidFallbackFont)
    AddPagesResult(if (coordinator.hasDocument) toPublicPageInfo(surface.currentPageInfo()) else null, added.toDouble())
  }

  override fun removePage(): Promise<PageInfo> = launchPromise {
    core.removePage(coordinator.activePageIndex.toDouble())
    toPublicPageInfo(surface.currentPageInfo())
  }

  override fun movePage(pageIndex: Double): Promise<PageInfo> = launchPromise {
    core.movePage(coordinator.activePageIndex.toDouble(), pageIndex)
    toPublicPageInfo(surface.currentPageInfo())
  }

  override fun rotatePage(degrees: Double): Promise<PageInfo> = launchPromise {
    surface.cancelInputGesture()
    core.rotatePage(coordinator.activePageIndex.toDouble(), degrees)
    toPublicPageInfo(surface.currentPageInfo())
  }

  override fun nextPage() {
    runOnMainSync { startPageNavigation(1) }
  }

  override fun previousPage() {
    runOnMainSync { startPageNavigation(-1) }
  }

  override fun getViewport(): Viewport {
    return runOnMainSync {
      checkMainThread()
      val state = surface.currentViewportState()
      Viewport(
        x = state.focus.x,
        y = state.focus.y,
        zoom = state.zoom,
      )
    }
  }

  override fun hasInk(): Boolean = runOnMainSync {
    checkMainThread()
    coordinator.activePageHasInk()
  }

  override fun setMode(mode: InputMode, options: TextModeOptions?): HybridModeSessionSpec =
    beginModeSession(mode, options)

  override fun requestPageCoords(): Promise<PageCoords> = runOnMainSync {
    invalidateModeSession()
    pickPageCoords(null)
  }

  internal fun requestSessionPageCoords(session: ModeSessionToken): Promise<PageCoords> = runOnMainSync {
    requireModeSession(session)
    pickPageCoords(session)
  }

  private fun pickPageCoords(session: ModeSessionToken?): Promise<PageCoords> {
    val result = Promise<PageCoords>()
    if (disposed) {
      result.reject(operationCancelled())
      return result
    }
    cancelCoordinateRequest()
    if ((session == null && currentModeSession != null) ||
      (session != null && !modeSessionIsCurrent(session))) {
      result.reject(operationCancelled())
      return result
    }
    val request = CoordinateRequest(result, session)
    pendingPageCoords = request
    // Only admission is queued. Waiting for the tap must not block replacement/close.
    launchPromise(presentation = true, modeSession = session) {
      if (pendingPageCoords !== request) throw operationCancelled()
      if (!coordinator.hasDocument) throw PdfSessionException(
        "document_not_open", "A document must be open before selecting page coordinates",
      )
      enterMode(edit = false, viewport = null)
      if (pendingPageCoords !== request) throw operationCancelled()
      val page = coordinator.page(coordinator.activePageIndex)
      request.target = CoordinateTarget(coordinator.generation, page.id, page.geometryRevision)
      surface.setCoordinatePicking(true)
      emitState()
    }.catch { error ->
      runOnMainSync {
        if (pendingPageCoords === request) {
          cancelCoordinateRequest(error)
        }
      }
    }
    return result
  }

  private fun cancelCoordinateRequest(error: Throwable = operationCancelled()) {
    val pending = pendingPageCoords
    pendingPageCoords = null
    surface.setCoordinatePicking(false)
    val time = android.os.SystemClock.uptimeMillis()
    val cancel = MotionEvent.obtain(time, time, MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
    coordinateTapDetector.onTouchEvent(cancel)
    cancel.recycle()
    pending?.let(::restoreCoordinateMode)
    if (pending?.target != null) emitState()
    pending?.promise?.reject(error)
  }

  private fun restoreCoordinateMode(request: CoordinateRequest) {
    val session = request.session ?: return
    if (request.target == null || !modeSessionIsCurrent(session)) return
    surface.withStateTransaction {
      surface.setEditMode(session.mode == InputMode.INK, cancelNavigation = false)
      if (session.mode == InputMode.TEXT && modeSessionIsCurrent(session)) {
        textOverlay.armPlacement(session.generation, session.textOptions)
      }
    }
  }

  private fun coordinateTargetIsCurrent(target: CoordinateTarget): Boolean =
    !disposed && coordinator.hasDocument && coordinator.generation == target.generation &&
      coordinator.activePageId() == target.pageId &&
      coordinator.page(coordinator.activePageIndex).geometryRevision == target.geometryRevision

  private fun finishInteractionForLifecycle() {
    if (isPickingPageCoords) cancelCoordinateRequest()
    textOverlay.finishForLifecycle()
  }

  override fun undo() {
    runOnMainSync { runHistoryCommand(surface::undo) }
  }
  override fun redo() {
    runOnMainSync { runHistoryCommand(surface::redo) }
  }
  override fun clear() {
    runOnMainSync { runHistoryCommand(surface::clear) }
  }
  override fun clearInk() {
    runOnMainSync { surface.clearInk() }
  }
  override fun resetDirty() {
    runOnMainSync {
      coordinator.resetDirty()
      surface.notifyStateChange()
    }
  }

  override fun loadFonts(fonts: Array<NamedFontSource>): Promise<Unit> = launchPromise { core.fonts.load(fonts) }
  override fun getPage(pageIndex: Double?): Promise<HybridAnalyzedPageSpec> = preparePage(pageIndex)

  internal fun getSessionPage(session: ModeSessionToken, pageIndex: Double?): Promise<HybridAnalyzedPageSpec> = runOnMainSync {
    requireModeSession(session)
    val index = pageIndex ?: coordinator.activePageIndex.toDouble()
    if (!index.isFinite() || index < 0 || index % 1.0 != 0.0 || index >= coordinator.pageCount) {
      throw PdfSessionException("page_not_found", "The requested page index is outside the document")
    }
    preparePage(null, session, coordinator.page(index.toInt()).id)
  }

  private fun preparePage(pageIndex: Double?, session: ModeSessionToken? = null,
                          capturedPageId: String? = null): Promise<HybridAnalyzedPageSpec> =
    launchPromise(presentation = true, modeSession = session) {
    checkMainThread()
    if (disposed) throw operationCancelled()
    if (!coordinator.hasDocument) throw PdfSessionException(
      "document_not_open", "A document must be open before acquiring a prepared page",
    )
    val index = if (capturedPageId != null) {
      coordinator.pageIndexForId(capturedPageId) ?: throw operationCancelled()
    } else if (pageIndex == null) coordinator.activePageIndex else {
      if (!pageIndex.isFinite() || pageIndex < 0.0 || pageIndex % 1.0 != 0.0) {
        throw PdfSessionException("invalid_page_index", "The page index must be a non-negative integer")
      }
      if (pageIndex > Int.MAX_VALUE.toDouble()) throw PdfSessionException(
        "page_not_found", "The requested page index is outside the document",
      )
      pageIndex.toInt()
    }
    if (index !in 0 until coordinator.pageCount) throw PdfSessionException(
      "page_not_found", "The requested page index is outside the document",
    )
    val context = core.getPage(index.toDouble())
    if (session != null) requireModeSession(session)
    return@launchPromise HybridAnalyzedPage(this@HybridInkSignView, context, session)
  }

  internal fun resolvePreparedText(context: PreparedPageContext, options: ResolveTextOptions) =
    core.text.resolve(context, options.copy(direction = resolvedTextDirection(options.direction)))

  override fun getSelectedText(): Variant_HybridTextHandleSpec_NullType = runOnMainSync {
    if (disposed || coordinator.pageCount == 0) {
      return@runOnMainSync Variant_HybridTextHandleSpec_NullType.create(NullType.NULL)
    }
    val selection = textOverlay.selectedText()
      ?: return@runOnMainSync Variant_HybridTextHandleSpec_NullType.create(NullType.NULL)
    Variant_HybridTextHandleSpec_NullType.create(
      HybridTextHandle(this, coordinator.generation, selection.pageId, selection.textId),
    )
  }

  internal fun <T> withModeSession(session: ModeSessionToken?, action: () -> T): T = runOnMainSync {
    if (disposed) throw operationCancelled()
    session?.let(::requireModeSession)
    action()
  }

  private fun resolvedTextDirection(direction: TextDirection?): TextDirection =
    if (textOverlay.resolveDirection(direction)) TextDirection.RTL else TextDirection.LTR

  private fun viewerOptions(options: TextAnnotationOptions?): TextAnnotationOptions? =
    if (options?.direction == TextDirection.AUTO) options.copy(direction = resolvedTextDirection(options.direction)) else options

  internal fun readPreparedTextValue(context: TextPageContext, id: Double): String = core.withPage(context) {
    val target = core.text.target(context, id)
    textOverlay.draftText(target.id) ?: core.text.getValue(context, id)
  }

  internal fun setPreparedTextValue(context: TextPageContext, id: Double, text: String,
                                    options: TextAnnotationOptions? = null) = core.withPage(context) {
    val target = core.text.target(context, id)
    val proposed = viewerOptions(options)
    if (text.isNotEmpty() && textOverlay.setPreparedDraftText(target.id, text, proposed)) return@withPage
    if (text.isEmpty()) {
      core.fonts.resolve(proposed?.font)
      textOverlay.cancelPreparedDraft(target.id)
    }
    core.text.setValue(context, id, text, proposed)
  }

  internal fun setPreparedTextOptions(context: TextPageContext, id: Double,
                                      options: TextAnnotationOptions) = core.withPage(context) {
    val target = core.text.target(context, id)
    val proposed = checkNotNull(viewerOptions(options))
    if (!textOverlay.setPreparedDraftOptions(target.id, proposed)) core.text.setOptions(context, id, proposed)
  }

  internal fun adjustPreparedTextSize(context: TextPageContext, id: Double, delta: Double): Double = core.withPage(context) {
    val target = core.text.target(context, id)
    val draftSize = textOverlay.preparedDraftFontSize(target.id) ?: return@withPage core.text.adjustSize(context, id, delta)
    val size = (draftSize + delta).coerceIn(minimumTextFontSize, maximumTextFontSize)
    if (size != draftSize) textOverlay.setPreparedDraftOptions(target.id, TextAnnotationOptions(null, size, null, null, null, null, null))
    size
  }

  internal fun preparedTextEntry(context: TextPageContext, id: Double): TextEntry = core.withPage(context) {
    val entry = core.text.getEntry(context, id)
    textOverlay.draftText(id.toLong())?.let { entry.copy(value = it, valueSource = TextValueSource.ANNOTATION) } ?: entry
  }

  internal fun preparedTextEntries(context: TextPageContext): Array<TextEntry> = core.withPage(context) {
    core.text.getEntries(context).map { entry ->
      textOverlay.draftText(entry.id.toLong())?.let { entry.copy(value = it, valueSource = TextValueSource.ANNOTATION) } ?: entry
    }.toTypedArray()
  }

  internal fun focusPreparedText(
    context: TextPageContext,
    rawId: Double,
    options: TextFocusOptions?,
    session: ModeSessionToken? = null,
  ): Promise<Unit> = launchPromise(presentation = true, modeSession = session) {
    val target = core.withPage(context) { page ->
      val slot = core.text.target(context, rawId)
      page to slot
    }
    surface.requireModeTransitionReady()
    val (page, slot) = target
    val rule = core.text.requireHorizontalRule(slot, page)
    val bounds = core.text.displayedTargetBounds(slot, page)
    viewportRequestID += 1L
    val requestId = viewportRequestID
    finishInteractionForLifecycle()
    core.withPage(context) { }
    if (viewportRequestID != requestId) throw operationCancelled()
    surface.switchPage(checkNotNull(coordinator.pageIndexForId(page.id)))
    core.withPage(context) { }
    if (viewportRequestID != requestId) throw operationCancelled()
    val center = rule?.let { (it.left + it.right) / 2.0 } ?: (bounds.left + bounds.right) / 2.0
    val request = ViewportRequest.FocusRule(
      x = center,
      ruleY = rule?.y ?: (bounds.top + bounds.bottom) / 2.0,
      zoom = options?.zoom ?: 2.0,
      verticalAnchor = options?.verticalAnchor ?: FieldFocusVerticalAnchor.CENTER,
      edgeOffset = options?.edgeOffset ?: 0.0,
    )
    val capturedModeSession = session
    suspendCancellableCoroutine<Unit> { continuation ->
      surface.focusField(request,
        isCurrent = { !disposed && coordinator.generation == context.generation &&
          coordinator.pageForId(context.pageId) != null && viewportRequestID == requestId &&
          (capturedModeSession == null || modeSessionIsCurrent(capturedModeSession)) },
        completion = { if (continuation.isActive) continuation.resume(Unit) },
        cancelled = { if (continuation.isActive) continuation.resumeWithException(operationCancelled()) })
    }
  }

  private fun runHistoryCommand(command: () -> Unit) {
    checkMainThread()
    if (disposed) return
    surface.withStateTransaction {
      finishInteractionForLifecycle()
      command()
    }
  }

  private fun loadSnapCandidatesForTextPlacement(generation: Long, pageIndex: Int) {
    if (surface.hasSnapCandidateMeasurement(generation, pageIndex)) return
    val pageSwitchId = surface.currentPageSwitchId
    coordinator.horizontalSnapCandidates(generation, pageIndex) { result ->
      val candidates = result.getOrNull() ?: return@horizontalSnapCandidates
      mainHandler.post {
        if (!disposed) {
          surface.installSnapCandidateMeasurement(generation, pageIndex, pageSwitchId, candidates)
        }
      }
    }
  }

  override fun setTextDirection(direction: TextDirection) {
    runOnMainSync {
      checkMainThread()
      if (disposed) throw operationCancelled()
      textOverlay.setTextDirection(direction)
    }
  }

  private fun startPageNavigation(delta: Int) {
    checkMainThread()
    if (disposed) throw operationCancelled()
    val current = surface.currentPageInfo()
    val target = (current.pageIndex + delta).coerceIn(0, current.pageCount - 1)
    pageNavigationRequestID += 1L
    val requestID = pageNavigationRequestID
    if (target == current.pageIndex) return
    if (isPickingPageCoords) cancelCoordinateRequest()
    val requestGeneration = coordinator.generation
    if (!Handler(Looper.getMainLooper()).post {
        if (disposed || coordinator.generation != requestGeneration ||
          pageNavigationRequestID != requestID
        ) return@post
        try {
          surface.withStateTransaction {
            finishInteractionForLifecycle()
            surface.switchPage(target)
          }
        } catch (error: Throwable) {
          if (error !is PdfSessionException || error.code != "operation_cancelled") {
            Log.e("InkSignPdf", "Page navigation failed", error)
          }
        }
      }
    ) {
      throw operationCancelled()
    }
  }

  override fun finalize(): Promise<String> = launchPromise {
    surface.withStateTransaction { finishInteractionForLifecycle() }
    try { core.finalize(surface.strokeColor()) }
    catch (error: Throwable) { throw normalizeFinalizeError(error) }
  }

  override fun startDebugRecording() {
    runOnMainSync { if (!disposed) traceRecorder.start() }
  }

  override fun stopDebugRecording() {
    runOnMainSync { if (!disposed) traceRecorder.stop() }
  }

  override fun exportDebugRecording(): Promise<String> {
    return launchPromise {
      checkMainThread()
      val snapshot = traceRecorder.snapshotForExport()
      val output = artifactPolicy.allocateDebugRecording()
      try {
        withContext(Dispatchers.IO) {
          exportStrokeTrace(output, snapshot).absolutePath
        }
      } catch (error: Throwable) {
        withContext(Dispatchers.IO) { artifactPolicy.deleteExact(output) }
        throw error
      }
    }
  }

  private fun <T> launchPromise(
    presentation: Boolean = false,
    modeSession: ModeSessionToken? = null,
    operation: suspend () -> T,
  ): Promise<T> {
    val promise = Promise<T>()
    val pending = PendingPromise(presentation, modeSession)
    val register = {
      synchronized(this) {
        if (disposed) throw operationCancelled()
        pendingPromises[promise] = pending
      }
    }
    try {
      if (modeSession == null) register()
      else runOnMainSync { requireModeSession(modeSession); register() }
    } catch (error: Throwable) {
      promise.reject(error)
      return promise
    }
    val command = try {
      core.submit {
        try {
          modeSession?.let(::requireModeSession)
          synchronized(this@HybridInkSignView) { pending.started = true }
          val value = operation()
          modeSession?.let(::requireModeSession)
          resolvePromise(promise, value)
        } catch (error: Throwable) {
          rejectPromise(
            promise,
            if (error is kotlinx.coroutines.CancellationException) operationCancelled() else error,
          )
          throw error
        }
      }
    } catch (error: Throwable) {
      rejectPromise(promise, error)
      return promise
    }
    synchronized(this) { pending.job = command }
    // Cancellation before execution never enters the operation's settlement path.
    command.invokeOnCompletion { error -> if (error != null) rejectPromise(promise, error) }
    return promise
  }

  private fun cancelPresentationRequests() {
    runOnMainSync {
      invalidateModeSession()
      cancelCoordinateRequest()
      viewportRequestID += 1L
      pageNavigationRequestID += 1L
    }
    val superseded = synchronized(this) {
      pendingPromises.entries
        .filter { (_, pending) -> pending.presentation && pending.started }
        .map { it.key to it.value.job }
    }
    superseded.forEach { (_, job) -> job?.cancel() }
  }

  private fun <T> runTextCommand(action: () -> T): T {
    return runOnMainSync {
      checkMainThread()
      // Admit against the document state current when this command reaches the UI thread.
      if (disposed) throw operationCancelled()
      var result: T? = null
      surface.withStateTransaction {
        result = action()
      }
      checkNotNull(result)
    }
  }

  private fun <T> resolvePromise(promise: Promise<T>, result: T) {
    synchronized(this) {
      if (pendingPromises.remove(promise) == null) return
      promise.resolve(result)
    }
  }

  private fun <T> rejectPromise(promise: Promise<T>, error: Throwable) {
    synchronized(this) {
      if (pendingPromises.remove(promise) == null) return
      promise.reject(error)
    }
  }

  private fun prepareStructuralMutation(
    creatingDocument: Boolean = false,
  ) {
    checkMainThread()
    surface.withStateTransaction { finishInteractionForLifecycle() }
    surface.requireStructuralMutationReady(creatingDocument)
  }

  private fun operationCancelled(): PdfSessionException {
    return PdfSessionException(
      "operation_cancelled",
      "PDF view was disposed or the open was superseded",
    )
  }

  private fun normalizeFinalizeError(error: Throwable): Throwable {
    if (error !is PdfSessionException) return error
    if (error.code != "cache_unavailable" && error.code != "invalid_output_path") return error
    return PdfSessionException(
      "pdf_export_failed",
      "Unable to allocate or publish the native PDF export",
      error,
    )
  }

  private fun checkMainThread() {
    check(Looper.myLooper() == Looper.getMainLooper())
  }

  private fun <T> runOnMainSync(action: () -> T): T = core.onMain(action)

  private fun enterMode(edit: Boolean, viewport: ViewportOptions?) {
    checkMainThread()
    if (disposed) throw operationCancelled()
    if (!coordinator.hasDocument) return
    val request = ViewportRequestParser.parse(viewport)
    surface.requireModeTransitionReady()
    viewportRequestID += 1L
    surface.withStateTransaction {
      finishInteractionForLifecycle()
      surface.transitionToMode(edit, request)
    }
  }

  private fun beginModeSession(mode: InputMode, options: TextModeOptions? = null): HybridModeSessionSpec =
    runOnMainSync {
      if (disposed) throw operationCancelled()
      core.fonts.resolve(options?.font)
      if (!coordinator.hasDocument) {
        if (mode != InputMode.VIEW) throw viewNotReady()
        val token = ModeSessionToken(coordinator.generation, InputMode.VIEW)
        token.cancelled = true
        return@runOnMainSync HybridModeSession(this, token)
      }
      surface.requireModeTransitionReady()
      invalidateModeSession()
      val token = ModeSessionToken(coordinator.generation, mode, options)
      currentModeSession = token
      cancelCoordinateRequest()
      requireModeSession(token)
      applySessionMode(token)
      requireModeSession(token)
      HybridModeSession(this, token)
    }

  private fun applySessionMode(token: ModeSessionToken) {
    requireModeSession(token)
    surface.withStateTransaction {
      enterMode(token.mode == InputMode.INK, null)
      requireModeSession(token)
      if (token.mode == InputMode.TEXT) {
        textOverlay.armPlacement(token.generation, token.textOptions)
      }
    }
    if (token.mode == InputMode.TEXT) {
      loadSnapCandidatesForTextPlacement(token.generation, coordinator.activePageIndex)
    }
  }

  internal fun modeSessionIsCurrent(token: ModeSessionToken): Boolean =
    !disposed && !token.cancelled && currentModeSession === token &&
      coordinator.hasDocument && coordinator.generation == token.generation

  internal fun requireModeSession(token: ModeSessionToken) {
    checkMainThread()
    if (!modeSessionIsCurrent(token)) throw operationCancelled()
  }

  private fun invalidateModeSession() {
    checkMainThread()
    val token = currentModeSession ?: return
    currentModeSession = null
    token.cancelled = true
    viewportRequestID += 1L
    val retired = synchronized(this) {
      pendingPromises.filterValues { it.modeSession === token }.keys.toList()
    }
    // Reject callers immediately, but retain the coroutine's queue slot until its worker returns.
    retired.forEach { rejectPromise(it, operationCancelled()) }
  }

  internal fun setSessionViewport(token: ModeSessionToken, options: ViewportOptions?): Promise<Unit> =
    launchPromise(presentation = true, modeSession = token) {
      surface.requireModeTransitionReady()
      val request = ViewportRequestParser.parse(options)
      viewportRequestID += 1L
      val requestID = viewportRequestID
      finishInteractionForLifecycle()
      requireModeSession(token)
      suspendCancellableCoroutine<Unit> { continuation ->
        surface.focusField(request,
          isCurrent = { modeSessionIsCurrent(token) && viewportRequestID == requestID },
          completion = { if (continuation.isActive) continuation.resume(Unit) },
          cancelled = { if (continuation.isActive) continuation.resumeWithException(operationCancelled()) })
      }
    }

  private fun viewNotReady(): PdfSessionException {
    return PdfSessionException(
      "view_not_ready",
      "A PDF must be opened before changing mode",
    )
  }

  private fun updatePenConfiguration() {
    surface.setPenConfiguration(
      color = strokeColor,
      minWidth = strokeMinWidth,
      maxWidth = strokeMaxWidth,
      smoothing = strokeSmoothing,
    )
  }

  override fun onDropView() {
    checkMainThread()
    invalidateModeSession()
    val promises = synchronized(this) {
      if (disposed) return
      disposed = true
      viewportRequestID += 1L
      val pending = pendingPromises.keys.toList()
      pendingPromises.clear()
      pending
    }
    cancelCoordinateRequest()
    promises.forEach { promise -> promise.reject(operationCancelled()) }
    pageInputCoordinator.close()
    textOverlay.dispose()
    lowLatencyPresenter.release()
    documentSubscription.close()
    core.close(cancelPending = true)
    surface.dispose()
    inkEngine.close()
    onStateChange = null
    onPageChange = null
    onZoomChange = null
    textOverlay.onInteractionModeChanged = null
  }

  private var lastInkState = InkState(false, false, false)
  private var lastPublicState: ViewerState? = null

  private fun emitState() {
    if (disposed) return
    if (surface.stateNotificationsSuspended > 0) return
    if (coordinator.hasDocument && documentId == null) documentId = java.util.UUID.randomUUID().toString()
    if (!coordinator.hasDocument) documentId = null
    val value = ViewerState(
      documentId = documentId?.let { Variant_NullType_String.create(it) } ?: Variant_NullType_String.create(NullType.NULL),
      canUndo = lastInkState.canUndo,
      canRedo = lastInkState.canRedo,
      isDirty = lastInkState.isDirty,
      mode = if (isPickingPageCoords) InteractionMode.PAGECOORDS else textOverlay.interactionMode(),
      error = loadError?.let { Variant_NullType_String.create(it) } ?: Variant_NullType_String.create(NullType.NULL),
    )
    if (value == lastPublicState) return
    lastPublicState = value
    onStateChange?.invoke(value)
  }

  private fun toPublicPageInfo(info: PdfPageInfo): PageInfo {
    return PageInfo(
      pageIndex = info.pageIndex.toDouble(),
      pageCount = info.pageCount.toDouble(),
      width = info.dimensions.width,
      height = info.dimensions.height,
    )
  }

}
