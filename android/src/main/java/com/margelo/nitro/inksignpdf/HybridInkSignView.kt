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
  internal val documentState: ViewerDocumentState get() = surface.documentState
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
    core = core,
  )
  private val textOverlay = TextInteractionOverlay(context, surface, core)
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
    }
  override var defaultTextColor: String? = null
    set(value) {
      field = value
      textOverlay.setDefaultTextColor(value)
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
  override var onPageChange: ((PageChangeEvent) -> Unit)? = null
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
    surface.onStateChange = {
      if (!disposed && !surface.isOpenHandoffInProgress) {
        emitState()
      }
    }
    surface.onPageChange = { page ->
      pendingPageCoords?.target?.let { if (!coordinateTargetIsCurrent(it)) cancelCoordinateRequest() }
      if (!disposed && !surface.isOpenHandoffInProgress) emitState()
    }
    surface.onZoomChange = { zoom -> if (!disposed) onZoomChange?.invoke(zoom) }
  }

  private var loadError: String? = null
  private var importSelection = AddPagesActivePage.CURRENT

  override fun open(path: String, options: ViewOpenOptions?): Promise<PageInfo> {
    cancelPresentationRequests()
    return launchPromise {
      var pendingOpen: MutableDocumentCoordinator.PendingOpen? = null
      loadError = null
      emitState()
      try {
        val viewport = ViewportRequestParser.parseOpen(options?.let { ViewportOptions(it.x, it.y, it.zoom) })
        logFallbackFontSnapshot(androidFallbackFont)
        val pending = core.prepareOpen(path, DocumentOpenOptions(tag = options?.tag, imagePageSize = null,
          targetDpi = null, jpegQuality = null, androidFallbackFont = androidFallbackFont))
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
        surface.clearDocument()
        editMode = false
        emitState()
      }
      DocumentChange.Opened -> {
        surface.publishOpenDocumentPresentation(checkNotNull(openPresentation))
        editMode = false
        surface.notifyPublishedOpenDocumentPresentation()
        emitState()
      }
      DocumentChange.WillChangePages -> prepareStructuralMutation(creatingDocument = !documentState.hasDocument)
      DocumentChange.Pages -> {
        viewportRequestID += 1L
        surface.installStructuralPresentation(importSelection)
      }
      is DocumentChange.Text -> surface.refreshCommittedText(change.pageId)
      is DocumentChange.Content -> surface.presentContentChange(change)
    }
    emitPageState()
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
    val explicit = AddPagesOptions(tag = options?.tag, type = options?.type, sources = sources,
      imagePageSize = options?.imagePageSize, targetDpi = options?.targetDpi,
      jpegQuality = options?.jpegQuality, activePage = options?.activePage)
    val dimensions = options?.imagePageSize?.let { PdfPageDimensions(it.width, it.height) }
      ?: (if (documentState.hasDocument) documentState.pageMetadata(documentState.activePageIndex).dimensions else PdfPageDimensions(595.28, 841.89))
    val added = try {
      importSelection = options?.activePage ?: AddPagesActivePage.CURRENT
      core.addPages(explicit, dimensions, androidFallbackFont)
    } finally { importSelection = AddPagesActivePage.CURRENT }
    AddPagesResult(if (documentState.hasDocument) toPublicPageInfo(surface.currentPageInfo()) else null, added.toDouble())
  }

  override fun removePage(): Promise<PageInfo> = launchPromise {
    core.removePage(documentState.activePageIndex.toDouble())
    toPublicPageInfo(surface.currentPageInfo())
  }

  override fun movePage(pageIndex: Double): Promise<PageInfo> = launchPromise {
    core.movePage(documentState.activePageIndex.toDouble(), pageIndex)
    toPublicPageInfo(surface.currentPageInfo())
  }

  override fun rotatePage(degrees: Double): Promise<PageInfo> = launchPromise {
    surface.cancelInputGesture()
    core.rotatePage(documentState.activePageIndex.toDouble(), degrees)
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

  override fun getState(): DocumentState = core.documentInfo()

  override fun setMode(mode: InputMode, options: TextModeOptions?): HybridModeSessionSpec =
    beginModeSession(mode, options)

  override fun requestUserTap(): Promise<PageCoords> = runOnMainSync {
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
      if (!documentState.hasDocument) throw PdfSessionException(
        "document_not_open", "A document must be open before selecting page coordinates",
      )
      enterMode(edit = false, viewport = null)
      if (pendingPageCoords !== request) throw operationCancelled()
      val page = documentState.pageMetadata(documentState.activePageIndex)
      request.target = CoordinateTarget(documentState.generation, page.id, page.geometryRevision)
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
    !disposed && documentState.hasDocument && documentState.generation == target.generation &&
      documentState.activePageId() == target.pageId &&
      documentState.pageMetadata(documentState.activePageIndex).geometryRevision == target.geometryRevision

  private fun finishInteractionForLifecycle() {
    if (isPickingPageCoords) cancelCoordinateRequest()
    textOverlay.finishForLifecycle()
  }

  override fun undo() {
    runOnMainSync { runHistoryCommand(core::undo) }
  }
  override fun redo() {
    runOnMainSync { runHistoryCommand(core::redo) }
  }
  override fun clear() {
    runOnMainSync { runHistoryCommand(core::clearContent) }
  }
  override fun clearInk() {
    runOnMainSync {
      if (disposed) return@runOnMainSync
      surface.prepareContentMutation()
      if (documentState.hasDocument) core.clearInk(documentState.activePageId())
    }
  }
  override fun loadFonts(fonts: Array<NamedFontSource>): Promise<Unit> = launchPromise { core.fonts.load(fonts) }
  override fun getPage(pageIndex: Variant_Double_TaggedPageQuery?): Promise<HybridAnalyzedPageSpec> = preparePage(pageIndex)
  override fun getPageIdsByTag(tag: String): Array<String> = core.getPageIdsByTag(tag)

  internal fun getSessionPage(session: ModeSessionToken, pageIndex: Variant_Double_TaggedPageQuery?): Promise<HybridAnalyzedPageSpec> = runOnMainSync {
    requireModeSession(session)
    if (pageIndex is Variant_Double_TaggedPageQuery.Second) return@runOnMainSync preparePage(pageIndex, session)
    val index = pageIndex?.asFirstOrNull() ?: documentState.activePageIndex.toDouble()
    if (!index.isFinite() || index < 0 || index % 1.0 != 0.0 || index >= documentState.pageCount) {
      throw PdfSessionException("page_not_found", "The requested page index is outside the document")
    }
    preparePage(null, session, documentState.pageMetadata(index.toInt()).id)
  }

  private fun preparePage(pageIndex: Variant_Double_TaggedPageQuery?, session: ModeSessionToken? = null,
                          capturedPageId: String? = null): Promise<HybridAnalyzedPageSpec> =
    launchPromise(presentation = true, modeSession = session) {
    checkMainThread()
    if (disposed) throw operationCancelled()
    if (!documentState.hasDocument) throw PdfSessionException(
      "document_not_open", "A document must be open before acquiring a prepared page",
    )
    val context = when {
      capturedPageId != null -> core.getPage((documentState.pageIndexForId(capturedPageId) ?: throw operationCancelled()).toDouble())
      pageIndex == null -> core.getPage(documentState.activePageIndex.toDouble())
      else -> pageIndex.match({ core.getPage(it) }, { core.getPage(it) })
    }
    if (session != null) requireModeSession(session)
    return@launchPromise HybridAnalyzedPage(this@HybridInkSignView, context, session)
  }

  internal fun resolvePreparedText(context: PreparedPageContext, options: InputTargetResolutionOptions) =
    core.text.resolve(context, options.copy(direction = resolvedTextDirection(options.direction)))

  override fun getSelectedText(): Variant_HybridTextHandleSpec_NullType = runOnMainSync {
    if (disposed || documentState.pageCount == 0) {
      return@runOnMainSync Variant_HybridTextHandleSpec_NullType.create(NullType.NULL)
    }
    val selection = textOverlay.selectedText()
      ?: return@runOnMainSync Variant_HybridTextHandleSpec_NullType.create(NullType.NULL)
    Variant_HybridTextHandleSpec_NullType.create(
      HybridTextHandle(this, documentState.generation, selection.pageId, selection.textId),
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
    val targetId = core.text.targetId(context, id)
    textOverlay.draftText(targetId) ?: core.text.getValue(context, id)
  }

  internal fun setPreparedTextValue(context: TextPageContext, id: Double, text: String,
                                    options: TextAnnotationOptions? = null) = core.withPage(context) {
    val targetId = core.text.targetId(context, id)
    val proposed = viewerOptions(options)
    if (text.isNotEmpty() && textOverlay.setPreparedDraftText(targetId, text, proposed)) return@withPage
    if (text.isEmpty()) {
      core.fonts.resolve(proposed?.font)
      textOverlay.cancelPreparedDraft(targetId)
    }
    core.text.setValue(context, id, text, proposed)
  }

  internal fun setPreparedTextOptions(context: TextPageContext, id: Double,
                                      options: TextAnnotationOptions) = core.withPage(context) {
    val targetId = core.text.targetId(context, id)
    val proposed = checkNotNull(viewerOptions(options))
    if (!textOverlay.setPreparedDraftOptions(targetId, proposed)) core.text.setOptions(context, id, proposed)
  }

  internal fun adjustPreparedTextSize(context: TextPageContext, id: Double, delta: Double): Double = core.withPage(context) {
    val targetId = core.text.targetId(context, id)
    val draftSize = textOverlay.preparedDraftFontSize(targetId) ?: return@withPage core.text.adjustSize(context, id, delta)
    val size = (draftSize + delta).coerceIn(minimumTextFontSize, maximumTextFontSize)
    if (size != draftSize) textOverlay.setPreparedDraftOptions(targetId, TextAnnotationOptions(null, null, size, null, null, null, null, null))
    size
  }

  internal fun preparedInputTarget(context: TextPageContext, id: Double): InputTarget = core.withPage(context) {
    val entry = core.text.getEntry(context, id)
    textOverlay.draftText(id.toLong())?.let { entry.copy(value = it, valueSource = TextValueSource.ANNOTATION) } ?: entry
  }

  internal fun preparedTextEntries(context: TextPageContext): Array<InputTarget> = core.withPage(context) {
    core.text.getEntries(context).map { entry ->
      textOverlay.draftText(entry.id.toLong())?.let { entry.copy(value = it, valueSource = TextValueSource.ANNOTATION) } ?: entry
    }.toTypedArray()
  }

  internal fun focusPreparedText(
    context: TextPageContext,
    rawId: Double,
    options: InputTargetFocusOptions?,
    session: ModeSessionToken? = null,
  ): Promise<Unit> = launchPromise(presentation = true, modeSession = session) {
    val target = core.text.focusTarget(context, rawId)
    surface.requireModeTransitionReady()
    val rule = target.rule
    val bounds = target.bounds
    viewportRequestID += 1L
    val requestId = viewportRequestID
    finishInteractionForLifecycle()
    core.withPage(context) { }
    if (viewportRequestID != requestId) throw operationCancelled()
    surface.switchPage(checkNotNull(documentState.pageIndexForId(context.pageId)))
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
        isCurrent = { !disposed && documentState.generation == context.generation &&
          documentState.pageIndexForId(context.pageId) != null && viewportRequestID == requestId &&
          (capturedModeSession == null || modeSessionIsCurrent(capturedModeSession)) },
        completion = { if (continuation.isActive) continuation.resume(Unit) },
        cancelled = { if (continuation.isActive) continuation.resumeWithException(operationCancelled()) })
    }
  }

  private fun runHistoryCommand(command: (String) -> Unit) {
    checkMainThread()
    if (disposed) return
    surface.withStateTransaction {
      finishInteractionForLifecycle()
      surface.prepareContentMutation()
      if (documentState.hasDocument) command(documentState.activePageId())
    }
  }

  private fun loadSnapCandidatesForTextPlacement(generation: Long, pageIndex: Int) {
    if (surface.hasSnapCandidateMeasurement(generation, pageIndex)) return
    val pageSwitchId = surface.currentPageSwitchId
    core.requestSnapCandidates(generation, pageIndex) { result ->
      val candidates = result.getOrNull() ?: return@requestSnapCandidates
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
    val requestGeneration = documentState.generation
    if (!Handler(Looper.getMainLooper()).post {
        if (disposed || documentState.generation != requestGeneration ||
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
    if (!documentState.hasDocument) return
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
      if (!documentState.hasDocument) {
        if (mode != InputMode.VIEW) throw viewNotReady()
        val token = ModeSessionToken(documentState.generation, InputMode.VIEW)
        token.cancelled = true
        return@runOnMainSync HybridModeSession(this, token)
      }
      surface.requireModeTransitionReady()
      invalidateModeSession()
      val token = ModeSessionToken(documentState.generation, mode, options)
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
      loadSnapCandidatesForTextPlacement(token.generation, documentState.activePageIndex)
    }
  }

  internal fun modeSessionIsCurrent(token: ModeSessionToken): Boolean =
    !disposed && !token.cancelled && currentModeSession === token &&
      documentState.hasDocument && documentState.generation == token.generation

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

  private var lastPublicState: ViewerState? = null
  private var lastPublicPage: PageChangeEvent? = null

  private fun emitPageState() {
    if (disposed || surface.isOpenHandoffInProgress || surface.stateNotificationsSuspended > 0) return
    if (!documentState.hasDocument) { lastPublicPage = null; return }
    val value = documentState.pageChangeEvent(documentState.activePageIndex)
    if (value == lastPublicPage) return
    lastPublicPage = value
    onPageChange?.invoke(value)
  }

  private fun emitState() {
    if (disposed) return
    if (surface.stateNotificationsSuspended > 0) return
    emitPageState()
    val document = documentState.documentInfo()
    val value = ViewerState(
      documentId = document.documentId,
      pageCount = document.pageCount,
      pageIndex = if (documentState.hasDocument) Variant_NullType_Double.create(documentState.activePageIndex.toDouble())
        else Variant_NullType_Double.create(NullType.NULL),
      isDirty = document.isDirty,
      mode = if (isPickingPageCoords) InteractionMode.PAGECOORDS else textOverlay.interactionMode(),
      error = loadError?.let { Variant_NullType_String.create(it) } ?: Variant_NullType_String.create(NullType.NULL),
    )
    if (value == lastPublicState) return
    lastPublicState = value
    onStateChange?.invoke(value)
  }

  private fun toPublicPageInfo(info: PdfPageInfo): PageInfo {
    return documentState.pageInfo(info.pageIndex)
  }

}
