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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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
) : HybridInkSignViewSpec() {
  internal val attachedCore: DocumentCore? get() = attachedDocument?.core
  internal val core: DocumentCore get() = attachedCore ?: throw viewNotReady()
  private val attachmentId = java.util.UUID.randomUUID().toString()
  private var attachedDocument: HybridInkSignDocument? = null
  private val viewerScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val viewerCommands = Mutex()
  /** Options that created [attachedDocument]; non-null means the view owns and closes it. */
  private var ownedOptions: DocumentOptions? = null
  override var document: Variant_HybridInkSignDocumentSpec_DocumentOptions?
    get() = attachedDocument?.let { Variant_HybridInkSignDocumentSpec_DocumentOptions.First(it) }
    set(value) = runOnMainSync {
      if (disposed) return@runOnMainSync
      when (value) {
        null -> attachDocument(null, ownedOptions = null)
        is Variant_HybridInkSignDocumentSpec_DocumentOptions.First ->
          attachDocument(value.value as? HybridInkSignDocument ?: throw operationCancelled(), ownedOptions = null)
        is Variant_HybridInkSignDocumentSpec_DocumentOptions.Second -> {
          val options = value.value
          if (ownedOptions?.hasSameContent(options) == true) return@runOnMainSync
          attachDocument(HybridInkSignDocument.create(context.applicationContext, options), ownedOptions = options)
        }
      }
    }

  private fun attachDocument(next: HybridInkSignDocument?, ownedOptions: DocumentOptions?) {
    if (next === attachedDocument) return
    try { next?.core?.claimViewer(attachmentId) }
    catch (error: Throwable) { loadError = error.message; emitState(); return }
    detachDocument()
    attachedDocument = next
    this.ownedOptions = ownedOptions
    loadError = next?.core?.initializationError?.message
    viewerCanvas.bindCore(next?.core)
    textOverlay.bindCore(next?.core)
    textOverlay.setTextDirection(textDirection ?: TextDirection.AUTO)
    defaultTextFontSize?.let(textOverlay::setDefaultFontSize)
    defaultTextColor?.let(textOverlay::setDefaultTextColor)
    updatePenConfiguration()
    documentSubscription = next?.core?.observe(::documentChanged)
    lastPublicPage = null
    lastPublicState = null
    if (documentState.hasDocument) viewerCanvas.installDocumentPresentation(notifyState = true)
    emitState()
  }

  /** Detaches the current document and closes it when the view owns it. */
  private fun detachDocument(commitDraft: Boolean = true) {
    viewportRequestID += 1L
    pageNavigationRequestID += 1L
    if (commitDraft && documentState.hasDocument) finishInteractionForLifecycle()
    invalidateModeSession()
    cancelCoordinateRequest()
    synchronized(this) { pendingPromises.values.mapNotNull { it.job }.forEach { it.cancel() } }
    documentSubscription?.close()
    documentSubscription = null
    attachedCore?.releaseViewer(attachmentId)
    val previous = attachedDocument
    attachedDocument = null
    if (ownedOptions != null) previous?.close()
    ownedOptions = null
    viewerCanvas.bindCore(null)
    textOverlay.bindCore(null)
  }
  private val artifactPolicy = CacheArtifactPolicy.initialize(context)
  private val container: FrameLayout = object : FrameLayout(context) {
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
      if (event.actionMasked == MotionEvent.ACTION_DOWN) coordinateTouchActive = isPickingPageCoords
      if (!coordinateTouchActive) return super.dispatchTouchEvent(event)
      // The whole stream stays with the picker, including cancellation or resolution at UP.
      viewerCanvas.handleViewportTouch(event)
      coordinateTapDetector.onTouchEvent(event)
      if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
        coordinateTouchActive = false
      }
      return true
    }
  }
  internal fun isAttachedTo(capturedCore: DocumentCore): Boolean = !disposed && attachedCore === capturedCore
  internal val documentState: ViewerDocumentState get() = viewerCanvas.documentState
  private val inkEngine = InkEngine()
  private val lowLatencyPresenter = LowLatencyInkPresenter(
    context,
    mainView = container,
  )
  private val traceRecorder = createStrokeTraceRecorder()
  private val viewerCanvas = ViewerCanvas(
    context,
    inkEngine,
    traceRecorder,
    lowLatencyInk = lowLatencyPresenter,
    core = null,
  )
  private val textOverlay = TextInteractionOverlay(context, viewerCanvas)
  private val mainHandler = Handler(Looper.getMainLooper())
  @Volatile private var viewportRequestID = 0L
  private var pageNavigationRequestID = 0L
  @Volatile private var disposed = false
  private var currentModeSession: ModeSessionToken? = null
  private var documentSubscription: AutoCloseable? = null
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
      val coordinates = viewerCanvas.pageCoordinatesAt(event.x.toDouble(), event.y.toDouble()) ?: return false
      pendingPageCoords = null
      viewerCanvas.setCoordinatePicking(false)
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
      viewerCanvas.setDoubleTapConfiguration(value)
    }
  override var keyboardAvoidanceEnabled: Boolean? = null
    set(value) {
      field = value
      viewerCanvas.setKeyboardAvoidanceEnabled(value != false)
      textOverlay.refreshKeyboardAvoidance()
    }
  override var pagerDirection: PagerDirection? = null
    set(value) {
      field = value
      viewerCanvas.setPagerDirection(value)
    }
  override var onStateChange: ((ViewerState) -> Unit)? = null
    set(value) {
      field = value
      lastPublicState = null
      runOnMainSync { emitState() }
    }
  override var onPageChange: ((PageChangeEvent) -> Unit)? = null
    set(value) {
      field = value
      runOnMainSync {
        lastPublicPage = null
        emitPageState()
      }
    }
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
      viewerCanvas,
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
    viewerCanvas.textAnnotationBeingEdited = textOverlay::editingAnnotationId
    viewerCanvas.onTextContentChanged = { textOverlay.syncContent() }
    viewerCanvas.onTextTransformChanged = { textOverlay.syncTransform() }
    viewerCanvas.onModeChanged = {
      textOverlay.cancelPendingPlacement()
      if (viewerCanvas.isEditMode) textOverlay.clearSelectionForHostMode()
    }
    viewerCanvas.onWindowFocusLost = textOverlay::finishForLifecycle
    textOverlay.onInteractionModeChanged = {
      emitState()
    }
    textOverlay.setDefaultFontSize(defaultTextFontSize)
    viewerCanvas.onStateChange = {
      if (!disposed) {
        emitState()
      }
    }
    viewerCanvas.onPageChange = { page ->
      pendingPageCoords?.target?.let { if (!coordinateTargetIsCurrent(it)) cancelCoordinateRequest() }
      if (!disposed) emitState()
    }
    viewerCanvas.onZoomChange = { zoom -> if (!disposed) onZoomChange?.invoke(zoom) }
  }

  private var loadError: String? = null

  private fun documentChanged(change: DocumentChange) {
    if (attachedDocument != null && change == DocumentChange.Cleared) {
      detachDocument(commitDraft = false)
      emitState()
      return
    }
    when (change) {
      is DocumentChange.LoadFailed -> {
        loadError = change.error.message
        emitState()
      }
      is DocumentChange.EditEnded -> textOverlay.endEditorTransaction(change.edit)
      is DocumentChange.InkCleared -> {
        if (documentState.hasDocument && documentState.activePageId() == change.pageId)
          viewerCanvas.cancelInputGesture(cancelEngineWhenIdle = true)
      }
      DocumentChange.StructuralReady -> {
        viewerCanvas.setStructuralWriteActive(false)
        if (documentState.hasDocument) viewerCanvas.installStructuralPresentation()
      }
      DocumentChange.HistoryResetStarted -> {
        textOverlay.finishEditing(keepingSelection = true)
        viewerCanvas.cancelInputGesture(cancelEngineWhenIdle = true)
      }
      DocumentChange.HistoryReset -> emitState()
      DocumentChange.WillClose -> {
        if (attachedDocument != null) {
          detachDocument()
          emitState()
        }
      }
      DocumentChange.Cleared -> {
        viewportRequestID += 1L
        pageNavigationRequestID += 1L
        textOverlay.cancelForDocumentReplacement()
        viewerCanvas.clearDocument()
        editMode = false
        emitState()
      }
      DocumentChange.StructuralWriteStarted -> {
        viewerCanvas.setStructuralWriteActive(true)
      }
      DocumentChange.Pages -> {
        viewerCanvas.setStructuralWriteActive(false)
        viewportRequestID += 1L
        if (attachedDocument?.core?.state?.hasDocument == true) viewerCanvas.installStructuralPresentation()
        else viewerCanvas.clearDocument()
        emitState()
      }
      is DocumentChange.Text -> viewerCanvas.refreshCommittedText(change.pageId)
      is DocumentChange.Content -> viewerCanvas.presentContentChange(change)
    }
    emitPageState()
  }

  override fun selectPage(index: Double) {
    selectPage(index, null)
  }

  internal fun selectPage(index: Double, session: ModeSessionToken?) {
    runOnMainSync {
      if (disposed) throw operationCancelled()
      session?.let(::requireModeSession)
      val current = viewerCanvas.currentPageInfo()
      if (!index.isFinite() || index < 0 || index % 1.0 != 0.0 || index >= current.pageCount) {
        throw PdfSessionException("invalid_page_index", "The page index is out of range")
      }
      navigateToPage(index.toInt(), current.pageIndex, session)
    }
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
      val state = viewerCanvas.currentViewportState()
      Viewport(
        x = state.focus.x,
        y = state.focus.y,
        zoom = state.zoom,
      )
    }
  }


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
      viewerCanvas.setCoordinatePicking(true)
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
    viewerCanvas.setCoordinatePicking(false)
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
    viewerCanvas.withStateTransaction {
      viewerCanvas.setEditMode(session.mode == InputMode.INK, cancelNavigation = false)
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

  internal fun getSessionPage(session: ModeSessionToken, pageIndex: Variant_Double_TaggedPageQuery?): Promise<HybridDocumentPageSpec> = runOnMainSync {
    requireModeSession(session)
    if (pageIndex is Variant_Double_TaggedPageQuery.Second) return@runOnMainSync preparePage(pageIndex, session)
    val index = pageIndex?.asFirstOrNull() ?: documentState.activePageIndex.toDouble()
    if (!index.isFinite() || index < 0 || index % 1.0 != 0.0 || index >= documentState.pageCount) {
      throw PdfSessionException("page_not_found", "The requested page index is outside the document")
    }
    preparePage(null, session, documentState.pageMetadata(index.toInt()).id)
  }

  private fun preparePage(pageIndex: Variant_Double_TaggedPageQuery?, session: ModeSessionToken? = null,
                          capturedPageId: String? = null): Promise<HybridDocumentPageSpec> =
    launchPromise(presentation = true, modeSession = session) {
    checkMainThread()
    if (disposed) throw operationCancelled()
    if (!documentState.hasDocument) throw PdfSessionException(
      "document_not_open", "A document must be open before acquiring a prepared page",
    )
    val capturedCore = core
    val context = capturedCore.submit {
      when {
        capturedPageId != null -> capturedCore.getPage((capturedCore.state.pageIndexForId(capturedPageId) ?: throw operationCancelled()).toDouble())
        pageIndex == null -> capturedCore.getPage(documentState.activePageIndex.toDouble())
        else -> pageIndex.match({ capturedCore.getPage(it) }, { capturedCore.getPage(it) })
      }
    }.await()
    if (!isAttachedTo(capturedCore)) throw operationCancelled()
    if (session != null) requireModeSession(session)
    return@launchPromise HybridDocumentPage(core, context, this@HybridInkSignView, session)
  }

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

  internal fun enqueueInputTargetFocus(
    context: TextPageContext,
    rawId: Double,
    options: InputTargetFocusOptions?,
    session: ModeSessionToken? = null,
  ): Promise<Unit> = launchPromise(presentation = true, modeSession = session) {
    val target = core.text.focusTarget(context, rawId)
    viewerCanvas.requireModeTransitionReady()
    val rule = target.rule
    val bounds = target.bounds
    viewportRequestID += 1L
    val requestId = viewportRequestID
    finishInteractionForLifecycle()
    core.withPage(context) { }
    if (viewportRequestID != requestId) throw operationCancelled()
    viewerCanvas.switchPage(checkNotNull(documentState.pageIndexForId(context.pageId)))
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
      viewerCanvas.focusField(request,
        isCurrent = { !disposed && documentState.generation == context.generation &&
          documentState.pageIndexForId(context.pageId) != null && viewportRequestID == requestId &&
          (capturedModeSession == null || modeSessionIsCurrent(capturedModeSession)) },
        completion = { if (continuation.isActive) continuation.resume(Unit) },
        cancelled = { if (continuation.isActive) continuation.resumeWithException(operationCancelled()) })
    }
  }

  override fun focusInputTarget(page: HybridDocumentPageSpec, id: Double, options: InputTargetFocusOptions?): Promise<Unit> =
    focusPageInputTarget(page, id, options)

  internal fun focusPageInputTarget(page: HybridDocumentPageSpec, id: Double, options: InputTargetFocusOptions?,
                                session: ModeSessionToken? = null): Promise<Unit> {
    val target = page as? HybridDocumentPage ?: throw operationCancelled()
    if (!isAttachedTo(target.core)) throw operationCancelled()
    return enqueueInputTargetFocus(target.context, id, options, session ?: target.modeSession)
  }

  private fun loadSnapCandidatesForTextPlacement(generation: Long, pageIndex: Int) {
    if (viewerCanvas.hasSnapCandidateMeasurement(generation, pageIndex)) return
    val pageSwitchId = viewerCanvas.currentPageSwitchId
    core.requestSnapCandidates(generation, pageIndex) { result ->
      val candidates = result.getOrNull() ?: return@requestSnapCandidates
      mainHandler.post {
        if (!disposed) {
          viewerCanvas.installSnapCandidateMeasurement(generation, pageIndex, pageSwitchId, candidates)
        }
      }
    }
  }

  override var textDirection: TextDirection? = null
    set(value) = runOnMainSync {
      field = value
      if (!disposed) textOverlay.setTextDirection(value ?: TextDirection.AUTO)
    }

  private fun startPageNavigation(delta: Int) {
    checkMainThread()
    if (disposed) throw operationCancelled()
    val current = viewerCanvas.currentPageInfo()
    val target = (current.pageIndex + delta).coerceIn(0, current.pageCount - 1)
    navigateToPage(target, current.pageIndex, null)
  }

  private fun navigateToPage(target: Int, currentIndex: Int, session: ModeSessionToken?) {
    pageNavigationRequestID += 1L
    val requestID = pageNavigationRequestID
    if (target == currentIndex) return
    if (isPickingPageCoords) cancelCoordinateRequest()
    val requestGeneration = documentState.generation
    if (!Handler(Looper.getMainLooper()).post {
        if (disposed || documentState.generation != requestGeneration ||
          pageNavigationRequestID != requestID
        ) return@post
        try {
          session?.let(::requireModeSession)
          viewerCanvas.withStateTransaction {
            finishInteractionForLifecycle()
            viewerCanvas.switchPage(target)
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
    var capturedCore: DocumentCore? = null
    val register = {
      synchronized(this) {
        if (disposed) throw operationCancelled()
        capturedCore = attachedCore
        pendingPromises[promise] = pending
      }
    }
    try {
      if (modeSession == null) runOnMainSync(register)
      else runOnMainSync { requireModeSession(modeSession); register() }
    } catch (error: Throwable) {
      promise.reject(error)
      return promise
    }
    val command = try {
      viewerScope.async { viewerCommands.withLock {
        try {
          if (attachedCore !== capturedCore) throw operationCancelled()
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
      } }
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

  private fun operationCancelled(): PdfSessionException {
    return PdfSessionException(
      "operation_cancelled",
      "PDF view was disposed or the open was superseded",
    )
  }

  private fun checkMainThread() {
    check(Looper.myLooper() == Looper.getMainLooper())
  }

  private fun <T> runOnMainSync(action: () -> T): T = onMainThread(action)

  private fun enterMode(edit: Boolean, viewport: ViewportOptions?) {
    checkMainThread()
    if (disposed) throw operationCancelled()
    if (!documentState.hasDocument) return
    val request = ViewportRequestParser.parse(viewport)
    viewerCanvas.requireModeTransitionReady()
    viewportRequestID += 1L
    viewerCanvas.withStateTransaction {
      finishInteractionForLifecycle()
      viewerCanvas.transitionToMode(edit, request)
    }
  }

  private fun beginModeSession(mode: InputMode, options: TextModeOptions? = null): HybridModeSessionSpec =
    runOnMainSync {
      if (disposed) throw operationCancelled()
      attachedCore?.fonts?.resolve(options?.font)
      if (!documentState.hasDocument) {
        if (mode != InputMode.VIEW) throw viewNotReady()
        val token = ModeSessionToken(documentState.generation, InputMode.VIEW)
        token.cancelled = true
        return@runOnMainSync HybridModeSession(this, token)
      }
      viewerCanvas.requireModeTransitionReady()
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
    viewerCanvas.withStateTransaction {
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
      viewerCanvas.requireModeTransitionReady()
      val request = ViewportRequestParser.parse(options)
      viewportRequestID += 1L
      val requestID = viewportRequestID
      finishInteractionForLifecycle()
      requireModeSession(token)
      suspendCancellableCoroutine<Unit> { continuation ->
        viewerCanvas.focusField(request,
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
    viewerCanvas.setPenConfiguration(
      color = strokeColor,
      minWidth = strokeMinWidth,
      maxWidth = strokeMaxWidth,
      smoothing = strokeSmoothing,
    )
  }

  override fun onDropView() {
    checkMainThread()
    detachDocument()
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
    textOverlay.dispose()
    lowLatencyPresenter.release()
    documentSubscription?.close()
    viewerScope.cancel()
    viewerCanvas.dispose()
    inkEngine.close()
    onStateChange = null
    onPageChange = null
    onZoomChange = null
    textOverlay.onInteractionModeChanged = null
  }

  private var lastPublicState: ViewerState? = null
  private var lastPublicPage: PageChangeEvent? = null

  private fun emitPageState() {
    if (disposed || viewerCanvas.stateNotificationsSuspended > 0) return
    if (!documentState.hasDocument) { lastPublicPage = null; return }
    val value = documentState.pageChangeEvent(documentState.activePageIndex)
    if (value == lastPublicPage) return
    lastPublicPage = value
    onPageChange?.invoke(value)
  }

  private fun emitState() {
    if (disposed) return
    if (viewerCanvas.stateNotificationsSuspended > 0) return
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

/** Compares option contents so equal view props keep the view-owned document. */
private fun DocumentOptions.hasSameContent(other: DocumentOptions): Boolean =
  copy(sources = null) == other.copy(sources = null) && sources.contentEquals(other.sources)
