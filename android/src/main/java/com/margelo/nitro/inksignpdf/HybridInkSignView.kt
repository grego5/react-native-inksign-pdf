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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
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
) : HybridInkSignViewSpec() {
  private val artifactPolicy = CacheArtifactPolicy.initialize(context)
  private val pageInputCoordinator = AndroidPageInputCoordinator(context, artifactPolicy)
  private val container = FrameLayout(context)
  private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val pdfWorker = PdfSessionWorker()
  private val inkEngine = InkEngine()
  private val lowLatencyPresenter = LowLatencyInkPresenter(
    context,
    mainView = container,
  )
  private val traceRecorder = createStrokeTraceRecorder()
  private val surface = SurfaceView(
    context,
    pdfWorker,
    inkEngine,
    traceRecorder,
    lowLatencyInk = lowLatencyPresenter,
  )
  private val textOverlay = TextInteractionOverlay(context, surface)
  private val pendingOutputs = LinkedHashSet<File>()
  private val ownedOutputs = LinkedHashSet<File>()
  @Volatile private var documentGeneration = 0L
  @Volatile private var viewportRequestID = 0L
  private var pageNavigationRequestID = 0L
  @Volatile private var disposed = false
  private var editMode = false
  private val pendingPromises = IdentityHashMap<Promise<*>, Unit>()

  override val view: View
    get() = container

  override var fallbackFont: PdfFallbackFont? = null
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
    textOverlay.onInteractionModeChanged = { emitState() }
    textOverlay.setDefaultFontSize(defaultTextFontSize)
    surface.onStateChange = { state ->
      if (!disposed) {
        lastInkState = state
        emitState()
      }
    }
    surface.onPageChange = { page ->
      if (!disposed) onPageChange?.invoke(toPublicPageInfo(page))
    }
  }

  override fun open(path: String, options: ViewportOptions?): Promise<PageInfo> {
    return launchPromise {
      val request = beginOpen(path, options)
      val info = awaitWorkerResult(request.generation) { completion ->
        pdfWorker.replace(
          path,
          request.generation,
          request.fallbackFont,
          completion,
        )
      }
      ensureCurrentOpen(request.generation, info)
      surface.setDocument(info, request.zoom, request.focus, request.fitToPage)
      textOverlay.syncContent()
      editMode = false
      surface.setEditMode(false)
      toPublicPageInfo(surface.currentPageInfo())
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

  private fun runHistoryCommand(command: () -> Unit) {
    checkMainThread()
    if (disposed) return
    surface.withStateTransaction {
      textOverlay.finishForLifecycle()
      command()
    }
  }

  override fun insertAnnotationOn() {
    runOnMainSync {
      checkMainThread()
      if (disposed) throw operationCancelled()
      if (textOverlay.hasPendingPlacement()) return@runOnMainSync
      surface.requireModeTransitionReady()
      viewportRequestID += 1L
      val requestID = viewportRequestID
      surface.withStateTransaction {
        textOverlay.finishForLifecycle()
        surface.transitionToMode(enabled = false, viewport = ViewportRequest.Preserve)
        if (disposed || requestID != viewportRequestID) throw operationCancelled()
        textOverlay.armPlacement(documentGeneration)
      }
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
    val requestGeneration = documentGeneration
    if (!Handler(Looper.getMainLooper()).post {
        if (disposed || documentGeneration != requestGeneration ||
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
      val snapshot = try {
        captureExport()
      } catch (error: Throwable) {
        throw normalizeFinalizeError(error)
      }
      try {
        val output = awaitWorkerResult(snapshot.generation) { completion ->
          pdfWorker.export(snapshot, artifactPolicy, completion)
        }
        publishExport(snapshot, output)
      } catch (error: Throwable) {
        retireExport(snapshot.outputPath)
        throw normalizeFinalizeError(error)
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

  private fun <T> launchPromise(operation: suspend () -> T): Promise<T> {
    val promise = Promise<T>()
    synchronized(this) {
      if (disposed) {
        promise.reject(operationCancelled())
        return promise
      }
      pendingPromises[promise] = Unit
    }
    mainScope.launch {
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
    return promise
  }

  private fun <T> runTextCommand(action: () -> T): T {
    val requestGeneration = synchronized(this) { documentGeneration }
    return runOnMainSync {
      checkMainThread()
      if (disposed || documentGeneration != requestGeneration) {
        throw operationCancelled()
      }
      var result: T? = null
      surface.withStateTransaction {
        result = action()
      }
      if (disposed || documentGeneration != requestGeneration) {
        throw operationCancelled()
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
    generation: Long,
    start: (((Result<T>) -> Unit) -> Unit),
  ): T {
    return suspendCancellableCoroutine { continuation ->
      start { result ->
        result.fold(
          onSuccess = { value -> continuation.resume(value) },
          onFailure = { error -> continuation.resumeWithException(error) },
        )
      }
      continuation.invokeOnCancellation {
        pdfWorker.cancel(generation)
      }
    }
  }

  private fun beginOpen(path: String, options: ViewportOptions?): OpenRequest {
    checkMainThread()
    if (disposed) throw operationCancelled()

    pageInputCoordinator.cancelPending()
    surface.withStateTransaction { textOverlay.finishForLifecycle() }
    val viewport = ViewportRequestParser.parseOpen(options)
    val fallbackFontSnapshot = fallbackFont
    if (BuildConfig.DEBUG) {
      Log.i(
        "InkSignPdf",
        "PDFium component fallback snapshot configured=${fallbackFontSnapshot != null} " +
          "path=${fallbackFontSnapshot?.path ?: ""}",
      )
    }

    val generation = synchronized(this) {
      documentGeneration += 1L
      viewportRequestID += 1L
      pageNavigationRequestID += 1L
      documentGeneration
    }
    editMode = false
    surface.setEditMode(false)
    surface.clearDocument()
    emitResetState()

    return OpenRequest(
      generation = generation,
      focus = viewport.focus,
      zoom = viewport.zoom,
      fitToPage = viewport.fitToPage,
      fallbackFont = fallbackFontSnapshot,
    )
  }

  private fun ensureCurrentOpen(generation: Long, info: PdfSessionInfo) {
    checkMainThread()
    if (disposed || documentGeneration != generation || info.generation != generation) {
      throw operationCancelled()
    }
  }

  private fun captureExport(): PdfExportSnapshot {
    checkMainThread()
    if (disposed) throw operationCancelled()
    val info = surface.currentDocumentInfo()
    val pages = surface.completedPagesSnapshot()
    if (pages.size != info.pageCount) {
      throw PdfSessionException(
        "view_not_ready",
        "The loaded PDF page state is incomplete",
      )
    }
    return PdfExportSnapshot(
      sourcePath = info.sourcePath,
      outputPath = artifactPolicy.allocateSignedOutput().path,
      pages = pages.map { page ->
        PdfPageExportSnapshot(
          pageIndex = page.pageIndex,
          dimensions = page.dimensions,
          strokes = page.strokes,
          textAnnotations = page.content.mapNotNull { content ->
            (content as? PageContent.Text)?.annotation
          },
        )
      },
      generation = info.generation,
      color = surface.strokeColor(),
    ).also { snapshot ->
      synchronized(this) { pendingOutputs += File(snapshot.outputPath) }
    }
  }

  private fun publishExport(snapshot: PdfExportSnapshot, outputPath: String): String {
    checkMainThread()
    val output = File(outputPath).canonicalFile
    val expected = File(snapshot.outputPath).canonicalFile
    synchronized(this) {
      if (disposed || documentGeneration != snapshot.generation || output != expected) {
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
    val requestID = viewportRequestID
    if (requestID != viewportRequestID) throw operationCancelled()
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

  private fun emitResetState() {
    lastInkState = InkState(false, false, false)
    emitState()
  }

  override fun onDropView() {
    checkMainThread()
    val promises = synchronized(this) {
      if (disposed) return
      disposed = true
      documentGeneration += 1L
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
    surface.dispose()
    inkEngine.close()
    val outputs = synchronized(this) {
      (pendingOutputs + ownedOutputs).toSet().also {
        pendingOutputs.clear()
        ownedOutputs.clear()
      }
    }
    pdfWorker.close(outputs, artifactPolicy::deleteExact)
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

  private class OpenRequest(
    val generation: Long,
    val focus: PagePoint?,
    val zoom: Double?,
    val fitToPage: Boolean,
    val fallbackFont: PdfFallbackFont?,
  )

}
