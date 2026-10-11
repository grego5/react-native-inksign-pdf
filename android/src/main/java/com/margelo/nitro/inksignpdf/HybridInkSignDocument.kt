package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Color
import android.net.Uri
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise
import java.lang.ref.WeakReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@DoNotStrip
class HybridInkSignDocumentFactory : HybridInkSignDocumentFactorySpec() {
  override fun openDoc(uri: String, options: DocumentOpenOptions?): Promise<HybridInkSignDocumentSpec> {
    val context = checkNotNull(NitroModules.applicationContext) { "React Native context is unavailable" }
    val document = HybridInkSignDocument(context)
    return document.open(uri, options)
  }
}

/** A document owns a worker and FIFO admissions, without constructing any Android view. */
@DoNotStrip
internal class HybridInkSignDocument(context: Context) : HybridInkSignDocumentSpec() {
  private val artifacts = CacheArtifactPolicy.initialize(context)
  private val input = PageInputCoordinator(context, artifacts)
  private val coordinator = MutableDocumentCoordinator(sessionWorker = PdfSessionWorker(), artifactPolicy = artifacts)
  private val owner = InkSignDocumentOwner(coordinator, NamedFontRegistry(context), recordHistory = false,
    appDirectionIsRtl = { com.facebook.react.modules.i18nmanager.I18nUtil.getInstance().isRTL(context) })
  private val fallback = AndroidFallbackFontResolver(context)
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private var tail = CompletableDeferred(Unit)
  private var closing = false
  private var closePromise: Promise<Unit>? = null

  private fun <T> command(work: suspend () -> T): Promise<T> = synchronized(this) {
    if (closing) return@synchronized Promise<T>().also { it.reject(cancelled()) }
    enqueue(work)
  }

  private fun <T> enqueue(work: suspend () -> T): Promise<T> {
    val previous = tail
    val finished = CompletableDeferred<Unit>()
    tail = finished
    val promise = Promise<T>()
    scope.launch {
      previous.await()
      try { promise.resolve(work()) } catch (error: Throwable) { promise.reject(error) }
      finally { finished.complete(Unit) }
    }
    return promise
  }

  internal fun open(uri: String, options: DocumentOpenOptions?): Promise<HybridInkSignDocumentSpec> = command {
    try {
      coordinator.fallbackFont = options?.androidFallbackFont?.let { fallback.resolve(it) }
      append(DocumentAddPagesOptions(arrayOf(uri), options?.imagePageSize, options?.targetDpi, options?.jpegQuality))
      this@HybridInkSignDocument
    } catch (error: Throwable) {
      release()
      synchronized(this@HybridInkSignDocument) { closing = true }
      throw error
    }
  }

  override val pageCount: Double get() = owner.withDocument { coordinator.pageCount.toDouble() }

  override fun getPage(index: Double): Promise<HybridDocumentPageSpec> = command {
    val pageIndex = pageIndex(index)
    val page = coordinator.page(pageIndex)
    val analysis = awaitResult<PdfiumPreparedPageAnalysis> {
      coordinator.preparePageAnalysis(coordinator.generation, pageIndex, it)
    }
    val context = PreparedPageContext(coordinator.generation, page.id, page.geometryRevision, pageIndex, analysis, page.sourceDimensions)
    HybridDocumentPage(owner, context)
  }

  override fun loadFonts(fonts: Array<NamedFontSource>): Promise<Unit> = command { owner.fonts.load(fonts) }
  override fun addPages(options: DocumentAddPagesOptions): Promise<DocumentAddPagesResult> = command { append(options) }

  private suspend fun append(options: DocumentAddPagesOptions): DocumentAddPagesResult {
    val imageDimensions = options.imagePageSize?.let { PdfPageDimensions(it.width, it.height) }
      ?: coordinator.pages.firstOrNull()?.dimensions ?: PdfPageDimensions(595.28, 841.89)
    val imports = AddPagesOptions(null, options.sources, options.imagePageSize, options.targetDpi, options.jpegQuality, null)
    return owner.appendPages(input, imports, imageDimensions, resolveFallback = { coordinator.fallbackFont },
      present = { DocumentAddPagesResult(it.toDouble(), coordinator.pageCount.toDouble()) })
  }

  override fun removePage(index: Double): Promise<Unit> = command {
    val source = pageIndex(index)
    if (coordinator.pageCount == 1) throw PdfSessionException("last_page_required", "The document must retain one page")
    coordinator.setActivePage(source)
    structural(PdfiumAssemblyRequest(PdfiumAssemblyOperation.REMOVE, pageIndex = source)) { coordinator.removeActiveCandidate() }
  }

  override fun movePage(fromIndex: Double, toIndex: Double): Promise<Unit> = command {
    val source = pageIndex(fromIndex); val destination = pageIndex(toIndex)
    if (source != destination) {
      coordinator.setActivePage(source)
      structural(PdfiumAssemblyRequest(PdfiumAssemblyOperation.MOVE, pageIndex = source, destinationIndex = destination)) {
        coordinator.moveActiveCandidate(destination)
      }
    }
  }

  private suspend fun structural(request: PdfiumAssemblyRequest, candidate: () -> MutableDocumentCoordinator.StructuralCandidate) {
    val operation = coordinator.beginOperation()
    try {
      coordinator.executeStructuralMutation(coordinator.generation, request,
        candidateBuilder = { candidate() }, validate = { _, _ -> }, present = { })
    } finally { coordinator.endOperation(operation) }
  }

  override fun rotatePage(index: Double, degrees: Double): Promise<Unit> = command {
    val page = coordinator.page(pageIndex(index))
    if (degrees != 90.0 && degrees != 180.0 && degrees != 270.0) throw PdfSessionException("invalid_page_rotation", "Use 90, 180, or 270 degrees")
    val operation = coordinator.beginOperation()
    try {
      val dimensions = PageCoordinates(page.dimensions).withRotation((page.dimensions.rotation + degrees.toInt() / 90) % 4)
      val candidate = coordinator.rotatePageCandidate(page.id, dimensions)
      coordinator.installCandidate(coordinator.sourcePath, candidate.pages, candidate.activePageId)
    } finally { coordinator.endOperation(operation) }
  }

  override fun finalize(): Promise<String> = command {
    requireOpen()
    val operation = coordinator.beginOperation()
    val snapshot = coordinator.captureExport(Color.BLACK)
    try {
      val path = awaitResult<String> { coordinator.exportSession(snapshot, it) }
      // Successful exports are transferred to the caller, never registered for owner cleanup.
      Uri.fromFile(java.io.File(path)).toString()
    } catch (error: Throwable) { artifacts.deleteExact(java.io.File(snapshot.outputPath)); throw error }
    finally { coordinator.endOperation(operation) }
  }

  override fun close(): Promise<Unit> = synchronized(this) {
    closePromise?.let { return@synchronized it }
    closing = true
    owner.runOnMainSync { owner.stopAdmissions() }
    enqueue { release() }.also { closePromise = it }
  }

  private suspend fun release() {
    val files = coordinator.workingFiles() + listOfNotNull(coordinator.currentWorkingFile())
    owner.invalidate()
    coordinator.dispose()
    awaitResult<Unit> { coordinator.sessionWorker.closeAwaited(files, artifacts::deleteExact, it) }
    owner.fonts.close()
  }

  override fun dispose() { close() }
  private fun requireOpen() { if (owner.closed || !coordinator.hasDocument) throw cancelled() }
  private fun pageIndex(index: Double): Int {
    requireOpen()
    if (!index.isFinite() || index < 0 || index % 1.0 != 0.0 || index >= coordinator.pageCount)
      throw PdfSessionException("page_not_found", "The page index is outside the document")
    return index.toInt()
  }
  private fun cancelled() = PdfSessionException("operation_cancelled", "The document is closed")
  private suspend fun <T> awaitResult(start: ((Result<T>) -> Unit) -> Unit): T = suspendCancellableCoroutine { continuation ->
    start { outcome -> outcome.fold({ continuation.resume(it) }, { continuation.resumeWithException(it) }) }
  }
}

@DoNotStrip
internal class HybridDocumentPage(owner: InkSignDocumentOwner, context: PreparedPageContext) : HybridDocumentPageSpec() {
  private val owner = WeakReference(owner)
  private val prepared = WeakReference(owner.retainPrepared(context))
  private val context: PreparedPageContext get() = prepared.get() ?: throw PdfSessionException("operation_cancelled", "The prepared page was released")
  private fun <T> use(action: (InkSignDocumentOwner) -> T): T = owner.get()?.let(action)
    ?: throw PdfSessionException("operation_cancelled", "The document has been released")
  override fun getInfo(): PageInfo = use { owner -> owner.withTextPage(context) { page ->
    val index = checkNotNull(owner.coordinator.pageIndexForId(page.id))
    PageInfo(index.toDouble(), owner.coordinator.pageCount.toDouble(), page.dimensions.width, page.dimensions.height)
  } }
  override fun resolveText(options: ResolveTextOptions) = use { it.resolvePreparedText(context, options) }
  override fun getTextValue(id: Double) = use { it.readPreparedTextValue(context, id) }
  override fun setTextValue(id: Double, text: String, options: TextAnnotationOptions?) = use { it.setPreparedTextValue(context, id, text, options) }
  override fun setTextOptions(id: Double, options: TextAnnotationOptions) = use { it.setPreparedTextOptions(context, id, options) }
  override fun adjustTextSize(id: Double, delta: Double) = use { it.adjustPreparedTextSize(context, id, delta) }
  override fun getTextEntry(id: Double) = use { it.preparedTextEntry(context, id) }
  override fun getTextEntries() = use { it.preparedTextEntries(context) }
}
