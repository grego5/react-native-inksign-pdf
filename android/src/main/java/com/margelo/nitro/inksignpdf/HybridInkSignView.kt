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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.util.IdentityHashMap
import java.util.LinkedHashSet
import java.util.concurrent.CountDownLatch
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Native PDF/signature view implementation for the generated Nitro spec. */
@DoNotStrip
class HybridInkSignView internal constructor(
    private val context: Context,
    sessionWorker: PdfSessionWorker = PdfSessionWorker(),
) : HybridInkSignViewSpec() {
  private val artifactPolicy = CacheArtifactPolicy.initialize(context)
  private val fallbackFontResolver = AndroidFallbackFontResolver(context.applicationContext)
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
  private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  internal val coordinator = MutableDocumentCoordinator(
    sessionWorker = sessionWorker,
    artifactPolicy = artifactPolicy,
  )
  internal val documentOwner = InkSignDocumentOwner(coordinator, NamedFontRegistry(context), recordHistory = true,
    appDirectionIsRtl = { com.facebook.react.modules.i18nmanager.I18nUtil.getInstance().isRTL(context) })
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
  private val textOverlay = TextInteractionOverlay(context, surface, documentOwner.fonts)
  private val pendingOutputs = LinkedHashSet<File>()
  private val ownedOutputs = LinkedHashSet<File>()
  private val mainHandler = Handler(Looper.getMainLooper())
  @Volatile private var viewportRequestID = 0L
  private var pageNavigationRequestID = 0L
  @Volatile private var disposed = false
  private var currentModeSession: ModeSessionToken? = null
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
  private data class PendingPromise(val presentation: Boolean, val modeSession: ModeSessionToken?, var job: Job? = null)
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
      documentOwner.defaultFontSize = normalizeTextFontSize(value)
    }
  override var defaultTextColor: String? = null
    set(value) {
      field = value
      textOverlay.setDefaultTextColor(value)
      documentOwner.defaultTextColor = parseTextColor(value, Color.BLACK)
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

  private val commandMutex = documentOwner.commandMutex
  private var documentId: String? = null
  private var loadError: String? = null

  override fun open(path: String, options: ViewportOptions?): Promise<PageInfo> {
    cancelPresentationRequests()
    return launchPromise {
      checkMainThread()
      if (disposed) throw operationCancelled()
      loadError = null
      runCatching { emitState() }
      try {
        val viewport = ViewportRequestParser.parseOpen(options)
        val fallbackFontSnapshot = androidFallbackFont
        logFallbackFontSnapshot(fallbackFontSnapshot)
        val pageInfo = coordinator.executeOpen(
          sourcePath = path,
          fallbackFont = fallbackFontSnapshot,
          resolveFallbackFont = fallbackFontResolver::resolve,
          awaitContainerSize = { surface.awaitUsableViewportSize() },
          invalidatePrevious = {
            pageInputCoordinator.cancelPending()
            viewportRequestID += 1L
            pageNavigationRequestID += 1L
            textOverlay.cancelForDocumentReplacement()
            documentId = null
            documentOwner.clearPrepared()
            surface.clearDocument()
            editMode = false
            lastInkState = InkState(false, false, false)
            runCatching { emitState() }
          },
          preparePresentation = { info, size ->
            val presentation = surface.prepareDocumentPresentation(info, viewport, size)
            presentation to toPublicPageInfo(presentation.pageInfo)
          },
          beginHandoff = { surface.beginOpenHandoff() },
          publishPresentation = { (prepared, pageInfo) ->
            viewportRequestID += 1L
            pageNavigationRequestID += 1L
            documentId = java.util.UUID.randomUUID().toString()
            surface.publishOpenDocumentPresentation(prepared)
            editMode = false
            pageInfo
          },
          notifyPublished = {
            surface.notifyPublishedOpenDocumentPresentation()
          },
          abortHandoff = { surface.abortOpenHandoff() },
        )
        lastInkState = InkState(false, false, false)
        runCatching { emitState() }
        pageInfo
      } catch (failure: Exception) {
        if (!disposed && failure !is kotlinx.coroutines.CancellationException &&
          (failure as? PdfSessionException)?.code != "operation_cancelled") {
          loadError = failure.message ?: "Unable to open PDF"
          runCatching { emitState() }
        }
        throw failure
      }
    }
  }

  override fun close(cancelPending: Boolean?): Promise<Unit> {
    cancelPresentationRequests()
    if (cancelPending == true) {
      runOnMainSync {
        val requests = synchronized(this) { pendingPromises.entries.map { it.key to it.value.job } }
        requests.forEach { (promise, job) -> rejectPromise(promise, operationCancelled()); job?.cancel() }
        closePublishedDocument()
      }
      return launchPromise { }
    }
    return launchPromise { closePublishedDocument() }
  }

  private fun closePublishedDocument() {
    pageInputCoordinator.cancelPending()
    viewportRequestID += 1L
    pageNavigationRequestID += 1L
    textOverlay.cancelForDocumentReplacement()
    documentOwner.clearPrepared()
    documentOwner.fonts.close()
    coordinator.closeDocument()
    documentId = null
    surface.clearDocument()
    editMode = false
    lastInkState = InkState(false, false, false)
    emitState()
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
    val active = if (coordinator.hasDocument) surface.currentPageInfo() else null
    val fallback = coordinator.fallbackFont
    val initialFontConfig = if (active == null) androidFallbackFont else null
    val imageDimensions = options?.imagePageSize?.let { PdfPageDimensions(it.width, it.height) }
      ?: active?.dimensions ?: PdfPageDimensions(595.28, 841.89)
    documentOwner.appendPages(pageInputCoordinator, options, imageDimensions,
      resolveFallback = { initialFontConfig?.let { fallbackFontResolver.resolve(it) } ?: fallback },
      beforeMutation = { prepareStructuralMutation(creatingDocument = active == null) },
      validate = { info, candidate -> surface.validateStructuralCandidate(info, candidate.pages, candidate.activePageId) },
      present = { added ->
        val pageInfo = if (added == 0) active else surface.installStructuralPresentation()
        AddPagesResult(pageInfo?.let(::toPublicPageInfo), added.toDouble())
      })
  }

  override fun removePage(): Promise<PageInfo> {
    return launchPromise {
      val operation = beginStructuralOperation()
      try {
        val generation = coordinator.generation
        val current = coordinator
        if (current.pageCount <= 1) {
          throw PdfSessionException("last_page_required", "The document must retain one page")
        }
        val removedIndex = current.activePageIndex
        coordinator.executeStructuralMutation(
          generation = generation,
          request = PdfiumAssemblyRequest(
              operation = PdfiumAssemblyOperation.REMOVE,
              pageIndex = removedIndex,
            ),
          candidateBuilder = { coordinator.removeActiveCandidate() },
          validate = { info, pageCandidate ->
            surface.validateStructuralCandidate(info, pageCandidate.pages, pageCandidate.activePageId)
          },
          present = { toPublicPageInfo(surface.installStructuralPresentation()) },
        )
      } finally {
        endOperation(operation)
      }
    }
  }

  override fun movePage(pageIndex: Double): Promise<PageInfo> {
    return launchPromise {
      val operation = beginStructuralOperation()
      try {
        val generation = coordinator.generation
        val current = coordinator
        if (pageIndex >= current.pageCount.toDouble()) {
          throw PdfSessionException("invalid_page_index", "The destination page index is invalid")
        }
        val destination = pageIndex.toInt()
        val source = current.activePageIndex
        if (source == destination) return@launchPromise toPublicPageInfo(surface.currentPageInfo())
        coordinator.executeStructuralMutation(
          generation = generation,
          request = PdfiumAssemblyRequest(
              operation = PdfiumAssemblyOperation.MOVE,
              pageIndex = source,
              destinationIndex = destination,
            ),
          candidateBuilder = { coordinator.moveActiveCandidate(destination) },
          validate = { info, pageCandidate ->
            surface.validateStructuralCandidate(info, pageCandidate.pages, pageCandidate.activePageId)
          },
          present = { toPublicPageInfo(surface.installStructuralPresentation()) },
        )
      } finally {
        endOperation(operation)
      }
    }
  }

  override fun rotatePage(degrees: Double): Promise<PageInfo> = launchPromise {
    val rotationDegrees = when (degrees) {
      90.0 -> 90
      180.0 -> 180
      270.0 -> 270
      else -> throw PdfSessionException(
        "invalid_page_rotation", "Page rotation must be 90, 180, or 270 degrees clockwise",
      )
    }
    checkMainThread()
    surface.cancelInputGesture()
    val operation = beginStructuralOperation()
    try {
      viewportRequestID += 1L
      val pageId = coordinator.activePageId()
      val page = checkNotNull(coordinator.pageForId(pageId))
      val dimensions = PageCoordinates(page.dimensions).withRotation(
        (page.dimensions.rotation + rotationDegrees / 90) % 4,
      )
      val candidate = coordinator.rotatePageCandidate(pageId, dimensions)
      coordinator.installCandidate(coordinator.sourcePath, candidate.pages, candidate.activePageId)
      toPublicPageInfo(surface.installStructuralPresentation())
    } finally {
      endOperation(operation)
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

  override fun loadFonts(fonts: Array<NamedFontSource>): Promise<Unit> = launchPromise { documentOwner.fonts.load(fonts) }
  private val textPresentation = object : DocumentTextPresentation {
    override fun draftText(id: Long) = textOverlay.draftText(id)
    override fun draftFontSize(id: Long) = textOverlay.preparedDraftFontSize(id)
    override fun setDraft(id: Long, text: String, options: TextAnnotationOptions?) =
      textOverlay.setPreparedDraftText(id, text, options)
    override fun setDraftOptions(id: Long, options: TextAnnotationOptions) =
      textOverlay.setPreparedDraftOptions(id, options)
    override fun cancelDraft(id: Long) { textOverlay.cancelPreparedDraft(id) }
    override fun resolveDirection(direction: TextDirection?) = textOverlay.resolveDirection(direction)
    override fun requireModeSession(token: ModeSessionToken) = this@HybridInkSignView.requireModeSession(token)
    override fun focusPreparedText(context: TextPageContext, id: Double, options: TextFocusOptions?) =
      this@HybridInkSignView.focusPreparedText(context, id, options)
    override fun contentChanged(generation: Long, pageId: String, before: TextAnnotation?, after: TextAnnotation?) {
      surface.refreshCommittedText(pageId)
    }
  }.also { documentOwner.presentation = java.lang.ref.WeakReference(it) }

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
    val generation = coordinator.generation
    val page = coordinator.page(index)
    val context = PreparedPageContext(
      generation, page.id, page.geometryRevision, index,
      awaitWorkerResult { completion -> coordinator.preparePageAnalysis(generation, index, completion) },
      page.sourceDimensions,
      session,
    )
    checkMainThread()
    if (disposed || coordinator.generation != generation || coordinator.pageForId(page.id) == null ||
      (session != null && !modeSessionIsCurrent(session))) {
      throw operationCancelled()
    }
    if (coordinator.textTargetsForPage(page.id).isNotEmpty()) {
      coordinator.retainTextSourceGlyphs(page.id, context.analysis.glyphs)
    }
    HybridAnalyzedPage(documentOwner, context)
  }

  internal fun resolvePreparedText(context: PreparedPageContext, options: ResolveTextOptions) =
    documentOwner.resolvePreparedText(context, options)

  override fun getSelectedText(): Variant_HybridTextHandleSpec_NullType = runOnMainSync {
    if (disposed || coordinator.pageCount == 0) {
      return@runOnMainSync Variant_HybridTextHandleSpec_NullType.create(NullType.NULL)
    }
    val selection = textOverlay.selectedText()
      ?: return@runOnMainSync Variant_HybridTextHandleSpec_NullType.create(NullType.NULL)
    Variant_HybridTextHandleSpec_NullType.create(
      HybridTextHandle(documentOwner, coordinator.generation, selection.pageId, selection.textId),
    )
  }

  internal fun readPreparedTextValue(context: TextPageContext, id: Double) = documentOwner.readPreparedTextValue(context, id)
  internal fun setPreparedTextValue(context: TextPageContext, id: Double, text: String, options: TextAnnotationOptions? = null) =
    documentOwner.setPreparedTextValue(context, id, text, options)
  internal fun setPreparedTextOptions(context: TextPageContext, id: Double, options: TextAnnotationOptions) =
    documentOwner.setPreparedTextOptions(context, id, options)
  internal fun adjustPreparedTextSize(context: TextPageContext, id: Double, delta: Double) = documentOwner.adjustPreparedTextSize(context, id, delta)
  internal fun preparedTextEntry(context: TextPageContext, id: Double) = documentOwner.preparedTextEntry(context, id)
  internal fun preparedTextEntries(context: TextPageContext) = documentOwner.preparedTextEntries(context)

  internal fun focusPreparedText(
    context: TextPageContext,
    rawId: Double,
    options: TextFocusOptions?,
  ): Promise<Unit> = launchPromise(presentation = true, modeSession = context.modeSession) {
    val target = documentOwner.withTextPage(context) { page ->
      val slot = documentOwner.requireTextTarget(context, rawId)
      page to slot
    }
    surface.requireModeTransitionReady()
    val (page, slot) = target
    val rule = documentOwner.requireHorizontalRule(slot, page)
    val bounds = documentOwner.displayedTargetBounds(slot, page)
    viewportRequestID += 1L
    val requestId = viewportRequestID
    finishInteractionForLifecycle()
    documentOwner.withTextPage(context) { }
    if (viewportRequestID != requestId) throw operationCancelled()
    surface.switchPage(checkNotNull(coordinator.pageIndexForId(page.id)))
    documentOwner.withTextPage(context) { }
    if (viewportRequestID != requestId) throw operationCancelled()
    val center = rule?.let { (it.left + it.right) / 2.0 } ?: (bounds.left + bounds.right) / 2.0
    val request = ViewportRequest.FocusRule(
      x = center,
      ruleY = rule?.y ?: (bounds.top + bounds.bottom) / 2.0,
      zoom = options?.zoom ?: 2.0,
      verticalAnchor = options?.verticalAnchor ?: FieldFocusVerticalAnchor.CENTER,
      edgeOffset = options?.edgeOffset ?: 0.0,
    )
    val capturedModeSession = context.modeSession
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

  override fun finalize(): Promise<String> {
    return launchPromise {
      val operation = beginFinalizeOperation()
      try {
        val snapshot = try {
          captureExport()
        } catch (error: Throwable) {
          throw normalizeFinalizeError(error)
        }
        try {
          val output = awaitWorkerResult { completion ->
            coordinator.exportSession(snapshot, completion)
          }
          android.net.Uri.fromFile(File(publishExport(snapshot, output))).toString()
        } catch (error: Throwable) {
          retireExport(snapshot.outputPath)
          throw normalizeFinalizeError(error)
        }
      } finally {
        endOperation(operation)
      }
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
    val job = mainScope.launch(start = CoroutineStart.LAZY) {
      try {
        commandMutex.withLock {
          modeSession?.let(::requireModeSession)
          val value = operation()
          modeSession?.let(::requireModeSession)
          resolvePromise(promise, value)
        }
      } catch (error: Throwable) {
        rejectPromise(promise, error)
      } finally {
        synchronized(this@HybridInkSignView) {
          pendingPromises.remove(promise)
        }
      }
    }
    synchronized(this) { pending.job = job }
    job.start()
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
        .filter { (promise, pending) -> pending.presentation }
        .map { it.key to it.value.job }
    }
    superseded.forEach { (promise, job) ->
      rejectPromise(promise, operationCancelled())
      job?.cancel()
    }
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

  private suspend fun <T> awaitWorkerResult(
    start: (((Result<T>) -> Unit) -> Unit),
  ): T {
    return suspendCancellableCoroutine { continuation ->
      start { result ->
        result.fold(
          onSuccess = { value -> continuation.resume(value) },
          onFailure = { error -> continuation.resumeWithException(error) },
        )
      }
    }
  }

  private fun beginStructuralOperation(
    allowNoDocument: Boolean = false,
    deferPreflight: Boolean = false,
  ): Long {
    checkMainThread()
    if (disposed) throw operationCancelled()
    return coordinator.beginOperation(requireDocument = !allowNoDocument) {
      if (coordinator.hasDocument && !deferPreflight) {
        prepareStructuralMutation()
      }
    }
  }

  private fun prepareStructuralMutation(
    creatingDocument: Boolean = false,
  ) {
    checkMainThread()
    surface.withStateTransaction { finishInteractionForLifecycle() }
    surface.requireStructuralMutationReady(creatingDocument)
  }

  private fun beginFinalizeOperation(): Long {
    checkMainThread()
    if (disposed) throw operationCancelled()
    return coordinator.beginOperation {
      surface.withStateTransaction { finishInteractionForLifecycle() }
    }
  }

  private fun endOperation(operationID: Long) {
    coordinator.endOperation(operationID)
  }

  private fun ensureCurrentStructural(generation: Long) {
    checkMainThread()
    if (disposed || coordinator.generation != generation) {
      throw operationCancelled()
    }
  }

  private fun captureExport(): PdfExportSnapshot {
    checkMainThread()
    if (disposed) throw operationCancelled()
    val snapshot = coordinator.captureExport(surface.strokeColor())
    return snapshot.also { snapshot ->
      synchronized(this) { pendingOutputs += File(snapshot.outputPath) }
    }
  }

  private fun publishExport(snapshot: PdfExportSnapshot, outputPath: String): String {
    checkMainThread()
    val output = File(outputPath).canonicalFile
    val expected = File(snapshot.outputPath).canonicalFile
    synchronized(this) {
      if (disposed || coordinator.generation != snapshot.generation || output != expected) {
        pendingOutputs.remove(expected)
        artifactPolicy.deleteExact(expected)
        throw operationCancelled()
      }
      pendingOutputs.remove(expected)
      ownedOutputs += expected
    }
    return expected.path
  }

  private suspend fun retireExport(outputPath: String) {
    val output = File(outputPath)
    val shouldDelete = synchronized(this) {
      pendingOutputs.remove(output) || ownedOutputs.remove(output)
    }
    if (shouldDelete) withContext(Dispatchers.IO) { artifactPolicy.deleteExact(output) }
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

  private fun <T> runOnMainSync(action: () -> T): T {
    if (Looper.myLooper() == Looper.getMainLooper()) return action()

    val latch = CountDownLatch(1)
    var value: T? = null
    var error: Throwable? = null
    val posted = Handler(Looper.getMainLooper()).post {
      try {
        value = action()
      } catch (throwable: Throwable) {
        error = throwable
      } finally {
        latch.countDown()
      }
    }
    if (!posted) throw operationCancelled()
    try {
      latch.await()
    } catch (interrupted: InterruptedException) {
      Thread.currentThread().interrupt()
      throw operationCancelled()
    }
    error?.let { throw it }
    @Suppress("UNCHECKED_CAST")
    return value as T
  }

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
      documentOwner.fonts.resolve(options?.font)
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
    documentOwner.releasePrepared(token)
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
    mainScope.cancel()
    lowLatencyPresenter.release()
    val workingFiles = coordinator.workingFiles() + listOfNotNull(coordinator.currentWorkingFile())
    surface.dispose()
    inkEngine.close()
    val outputs = synchronized(this) {
      (pendingOutputs + ownedOutputs).toSet().also {
        pendingOutputs.clear()
        ownedOutputs.clear()
      }
    }
    documentOwner.invalidate()
    coordinator.dispose()
    coordinator.sessionWorker.closeAwaited(outputs + workingFiles, artifactPolicy::deleteExact) { result ->
      result.getOrThrow()
      documentOwner.fonts.close()
    }
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
