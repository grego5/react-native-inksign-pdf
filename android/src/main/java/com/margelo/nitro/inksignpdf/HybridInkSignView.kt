package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.Promise
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
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
  private val fallbackFontResolver = AndroidFallbackFontResolver()
  private val pageInputCoordinator = PageInputCoordinator(context, artifactPolicy)
  private val container = FrameLayout(context)
  private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  internal val coordinator = MutableDocumentCoordinator(
    sessionWorker = sessionWorker,
    artifactPolicy = artifactPolicy,
  )
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
  private val textOverlay = TextInteractionOverlay(context, surface)
  private val pendingOutputs = LinkedHashSet<File>()
  private val ownedOutputs = LinkedHashSet<File>()
  private val mainHandler = Handler(Looper.getMainLooper())
  @Volatile private var viewportRequestID = 0L
  private var pageNavigationRequestID = 0L
  @Volatile private var disposed = false
  private var editMode = false
  private data class PendingPromise(val documentBound: Boolean, var job: Job? = null)
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
  override var onStateChange: ((StateChangeEvent) -> Unit)? = null
    set(value) {
      field = value
    }
  override var onPageChange: ((PageInfo) -> Unit)? = null
    set(value) {
      field = value
    }
  init {
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
        textOverlay.finishForLifecycle()
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
      if (!disposed && !surface.isOpenHandoffInProgress) onPageChange?.invoke(toPublicPageInfo(page))
    }
  }

  override fun open(path: String, options: ViewportOptions?): Promise<PageInfo> {
    return launchPromise {
      checkMainThread()
      if (disposed) throw operationCancelled()
      val openJob = currentCoroutineContext()[Job]
      val viewport = ViewportRequestParser.parseOpen(options)
      val fallbackFontSnapshot = androidFallbackFont
      logFallbackFontSnapshot(fallbackFontSnapshot)
      val pageInfo = coordinator.executeOpen(
        sourcePath = path,
        fallbackFont = fallbackFontSnapshot,
        resolveFallbackFont = fallbackFontResolver::resolve,
        awaitContainerSize = { surface.awaitUsableViewportSize() },
        invalidatePrevious = {
          cancelSupersededDocumentOperations(openJob)
          pageInputCoordinator.cancelPending()
          viewportRequestID += 1L
          pageNavigationRequestID += 1L
          textOverlay.cancelForDocumentReplacement()
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

  override fun addPages(options: AddPagesOptions?): Promise<AddPagesResult> {
    return launchPromise {
      val fontFallbackSnapshot = coordinator.fallbackFont
      val requestedImageSize = options?.imagePageSize?.let {
        PdfPageDimensions(it.width, it.height)
      }
      val operation = beginStructuralOperation(allowNoDocument = true, deferPreflight = true)
      var staged = emptyList<StagedPageInput>()
      try {
        val generation = coordinator.generation
        val activePage = if (coordinator.hasDocument) surface.currentPageInfo() else null
        val imageSize = requestedImageSize ?: activePage?.dimensions ?:
          PdfPageDimensions(595.28, 841.89)
        staged = pageInputCoordinator.stage(options)
        ensureCurrentStructural(generation)
        if (staged.isEmpty()) {
          return@launchPromise AddPagesResult(
            pageInfo = activePage?.let { toPublicPageInfo(it) },
            addedPageCount = 0.0,
          )
        }
        prepareStructuralMutation(creatingDocument = activePage == null)
        val inputs = withContext(Dispatchers.IO) {
          staged.map { input ->
            when (input.type) {
              PageType.PDF -> PdfiumAppendRequest(PageType.PDF, sourcePath = input.file.path)
              PageType.IMAGE -> ImagePageEncoder.encode(
                source = input.file,
                page = imageSize,
                targetDpi = options?.targetDpi,
                jpegQuality = options?.jpegQuality,
              )
            }
          }
        }
        ensureCurrentStructural(generation)
        val oldPageCount = coordinator.pageCount
        val request = PdfiumAssemblyRequest(
          operation = if (oldPageCount == 0) PdfiumAssemblyOperation.CREATE else PdfiumAssemblyOperation.APPEND,
          appendInputs = inputs,
        )
        coordinator.executeStructuralMutation(
          generation = generation,
          request = request,
          candidateBuilder = { info ->
            val addedDimensions = info.pages.drop(oldPageCount)
            if (addedDimensions.isEmpty()) {
              throw PdfSessionException("pdf_mutation_failed", "The append candidate contains no added pages")
            }
            coordinator.appendCandidate(
              addedDimensions,
              options?.activePage ?: AddPagesActivePage.CURRENT,
            )
          },
          validate = { info, pageCandidate ->
            surface.validateStructuralCandidate(info, pageCandidate.pages, pageCandidate.activePageId)
          },
          present = {
            val pageInfo = if (oldPageCount == 0) {
              surface.installDocumentPresentation(notifyState = true)
              surface.currentPageInfo()
            } else {
              surface.installStructuralPresentation()
            }
            AddPagesResult(
              pageInfo = toPublicPageInfo(pageInfo),
              addedPageCount = (coordinator.pageCount - oldPageCount).toDouble(),
            )
          },
          fontFallback = fontFallbackSnapshot,
        )
      } finally {
        pageInputCoordinator.release(staged)
        endOperation(operation)
      }
    }
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

  override fun enterEditMode(viewport: ViewportOptions?) {
    runOnMainSync { enterMode(edit = true, viewport) }
  }

  override fun enterViewMode(viewport: ViewportOptions?) {
    runOnMainSync { enterMode(edit = false, viewport) }
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

  override fun addTextAnnotation(
    text: String,
    bounds: TextAnnotationBounds,
    options: TextAnnotationOptions?,
  ) {
    runOnMainSync {
      checkMainThread()
      if (disposed) throw operationCancelled()
      textOverlay.addTextAnnotation(bounds, text, options)
    }
  }

  override fun insertTextByKey(
    text: String,
    key: String,
    options: TextInsertionByKeyOptions?,
  ): Promise<Unit> = launchPromise {
    checkMainThread()
    if (disposed) throw operationCancelled()
    val presentation = surface.textPresentationSnapshot() ?: throw PdfSessionException(
      "view_not_ready", "A published PDF page is required for key-based text insertion",
    )
    val generation = presentation.generation
    val pageIndex = presentation.pageIndex
    val pageId = presentation.pageId
    val page = presentation.page
    val directionRtl = textOverlay.resolveDirection(options?.direction)
    val lookup = awaitCapturedDocumentPageLookup(
      awaitLookup = { awaitKeyLookup(generation, pageIndex, key) },
      isTargetPageCurrent = { isCurrentTextTarget(generation, pageId) },
    )
    if (!lookup.hasLiteralMatch) {
      throw PdfSessionException("text_key_not_found", "The requested text key was not found on the captured page")
    }
    val placement = selectPdfiumTextKeyPlacement(
      lookup.matches,
      lookup.rules,
      options?.occurrence ?: TextKeyOccurrence.FIRST,
      directionRtl,
      page,
    ) ?: throw PdfSessionException(
      "text_rule_not_found", "The selected text key has no usable adjacent rule",
    )
    val rule = placement.rule
    val anchor = options?.verticalAnchor ?: TextVerticalAnchor.BOTTOM
    if (rule.y <= 0.0 || rule.y >= page.height) {
      throw PdfSessionException("text_rule_not_found", "The selected rule leaves no page area for text")
    }
    val bounds = if (anchor == TextVerticalAnchor.BOTTOM) {
      TextAnnotationBounds(placement.contentLeft, 0.0, placement.contentRight - placement.contentLeft, rule.y)
    } else {
      TextAnnotationBounds(placement.contentLeft, rule.y,
        placement.contentRight - placement.contentLeft, page.height - rule.y)
    }
    val commitOptions = TextAnnotationOptions(
      direction = if (directionRtl) TextDirection.RTL else TextDirection.LTR,
      maxLines = options?.maxLines,
      alignment = options?.alignment ?: TextAlignment.START,
      verticalAnchor = anchor,
    )
    checkMainThread()
    requireCurrentTextTarget(generation, pageId)
    surface.withStateTransaction {
      textOverlay.addTextAnnotation(bounds, text, commitOptions, requireVisibleLine = true,
        resolvedDirectionRtl = directionRtl,
        capturedPage = CapturedTextPage(generation, pageId, page))
    }
    Unit
  }

  private suspend fun awaitKeyLookup(
    generation: Long,
    pageIndex: Int,
    key: String,
  ): PdfiumKeyLookupPage = suspendCancellableCoroutine { continuation ->
    coordinator.lookupTextKey(generation, pageIndex, key) { result ->
      result.fold(
        onSuccess = { value -> continuation.resume(value) },
        onFailure = { error -> continuation.resumeWithException(error) },
      )
    }
  }

  private fun isCurrentTextTarget(generation: Long, pageId: String): Boolean =
    !disposed && coordinator.hasDocument && coordinator.generation == generation &&
      coordinator.pageIndexForId(pageId) != null

  private fun requireCurrentTextTarget(generation: Long, pageId: String) {
    if (!isCurrentTextTarget(generation, pageId)) throw operationCancelled()
  }

  private fun runHistoryCommand(command: () -> Unit) {
    checkMainThread()
    if (disposed) return
    surface.withStateTransaction {
      textOverlay.finishForLifecycle()
      command()
    }
  }

  override fun insertAnnotationOn(options: TextPlacementOptions?) {
    runOnMainSync {
      checkMainThread()
      if (disposed) throw operationCancelled()
      if (textOverlay.hasPendingPlacement()) return@runOnMainSync
      surface.requireModeTransitionReady()
      viewportRequestID += 1L
      val requestID = viewportRequestID
      val generation = coordinator.generation
      val pageIndex = surface.currentPageInfo().pageIndex
      surface.withStateTransaction {
        textOverlay.finishForLifecycle()
        surface.transitionToMode(enabled = false, viewport = ViewportRequest.Preserve)
        if (disposed || requestID != viewportRequestID) throw operationCancelled()
        textOverlay.armPlacement(generation, options)
      }
      loadSnapCandidatesForTextPlacement(generation, pageIndex)
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

  override fun insertAnnotationOff() {
    runOnMainSync {
      checkMainThread()
      if (disposed) throw operationCancelled()
      textOverlay.cancelPendingPlacement()
    }
  }

  override fun increaseTextSize(): Double = runTextCommand {
    textOverlay.increaseTextSize()
  }

  override fun decreaseTextSize(): Double = runTextCommand {
    textOverlay.decreaseTextSize()
  }

  override fun removeTextAnnotation() = runTextCommand {
    textOverlay.removeTextAnnotation()
  }

  private fun startPageNavigation(delta: Int) {
    checkMainThread()
    if (disposed) throw operationCancelled()
    val current = surface.currentPageInfo()
    val target = (current.pageIndex + delta).coerceIn(0, current.pageCount - 1)
    pageNavigationRequestID += 1L
    val requestID = pageNavigationRequestID
    if (target == current.pageIndex) return
    val requestGeneration = coordinator.generation
    if (!Handler(Looper.getMainLooper()).post {
        if (disposed || coordinator.generation != requestGeneration ||
          pageNavigationRequestID != requestID
        ) return@post
        try {
          surface.withStateTransaction {
            textOverlay.finishForLifecycle()
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
          publishExport(snapshot, output)
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
    return launchPromise(documentBound = false) {
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
    documentBound: Boolean = true,
    operation: suspend () -> T,
  ): Promise<T> {
    val promise = Promise<T>()
    val pending = PendingPromise(documentBound)
    synchronized(this) {
      if (disposed) {
        promise.reject(operationCancelled())
        return promise
      }
      pendingPromises[promise] = pending
    }
    val job = mainScope.launch(start = CoroutineStart.LAZY) {
      try {
        resolvePromise(promise, operation())
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

  private fun cancelSupersededDocumentOperations(currentJob: Job?) {
    val superseded = synchronized(this) {
      pendingPromises.entries
        .filter { (promise, pending) -> pending.documentBound && pending.job !== currentJob }
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

  private fun prepareStructuralMutation(creatingDocument: Boolean = false) {
    checkMainThread()
    surface.withStateTransaction { textOverlay.finishForLifecycle() }
    surface.requireStructuralMutationReady(creatingDocument)
  }

  private fun beginFinalizeOperation(): Long {
    checkMainThread()
    if (disposed) throw operationCancelled()
    return coordinator.beginOperation {
      surface.withStateTransaction { textOverlay.finishForLifecycle() }
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
    val request = ViewportRequestParser.parse(viewport)
    surface.requireModeTransitionReady()
    viewportRequestID += 1L
    surface.withStateTransaction {
      textOverlay.finishForLifecycle()
      surface.transitionToMode(edit, request)
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
    val promises = synchronized(this) {
      if (disposed) return
      disposed = true
      viewportRequestID += 1L
      val pending = pendingPromises.keys.toList()
      pendingPromises.clear()
      pending
    }
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
    coordinator.dispose()
    coordinator.closeSession(outputs + workingFiles, artifactPolicy::deleteExact)
    onStateChange = null
    onPageChange = null
    textOverlay.onInteractionModeChanged = null
  }

  private var lastInkState = InkState(false, false, false)
  private var lastPublicState: StateChangeEvent? = null

  private fun emitState() {
    if (disposed) return
    if (surface.stateNotificationsSuspended > 0) return
    val value = StateChangeEvent(
      canUndo = lastInkState.canUndo,
      canRedo = lastInkState.canRedo,
      isDirty = lastInkState.isDirty,
      mode = textOverlay.interactionMode(),
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

internal suspend fun <T> awaitCapturedDocumentPageLookup(
  awaitLookup: suspend () -> T,
  isTargetPageCurrent: () -> Boolean,
): T {
  val result = try {
    Result.success(awaitLookup())
  } catch (error: Throwable) {
    Result.failure(error)
  }
  if (!isTargetPageCurrent()) throw PdfSessionException(
    "operation_cancelled",
    "The document or captured page changed during text lookup",
  )
  return result.getOrThrow()
}
