package com.margelo.nitro.inksignpdf

import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.concurrent.CountDownLatch
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal sealed interface DocumentChange {
  data object Opening : DocumentChange
  data object Opened : DocumentChange
  data object Pages : DocumentChange
  data object StructuralWriteStarted : DocumentChange
  data object WillClose : DocumentChange
  data class EditEnded(val edit: DocumentTextEdit) : DocumentChange
  data object StructuralReady : DocumentChange
  data class InkCleared(val pageId: String) : DocumentChange
  data object Cleared : DocumentChange
  data class Text(val pageId: String) : DocumentChange
  data class Content(val generation: Long, val pageId: String, val mutation: InkHistoryMutation) : DocumentChange
}

internal enum class ExportOwnership { DOCUMENT, CALLER }

/** Owns document work and resources; clients own presentation and interaction. */
internal class DocumentCore(
  context: Context,
  val sessionWorker: PdfSessionWorker = PdfSessionWorker(),
  recordHistory: Boolean,
  private val exportOwnership: ExportOwnership,
) {
  val artifacts = CacheArtifactPolicy.initialize(context)
  internal val coordinator = MutableDocumentCoordinator(sessionWorker = sessionWorker, artifactPolicy = artifacts, recordHistory = recordHistory)
  val state: DocumentReadState = coordinator
  val fonts = NamedFontRegistry(context)
  val text = DocumentTextCommands(this,
    appDirectionIsRtl = { com.facebook.react.modules.i18nmanager.I18nUtil.getInstance().isRTL(context) })
  internal var activeTextEdit: DocumentTextEdit? = null
    private set
  private var structuralBusy = false
  internal fun requireContentMutationReady() {
    if (structuralBusy) throw PdfSessionException("operation_in_progress", "A structural write is active")
  }

  fun beginTextEdit(context: TextPageContext, id: Long): DocumentTextEdit = withMutablePage(context) { page ->
    requireContentMutationReady()
    endTextEdit()
    DocumentTextEdit(context, page, id,
      page.history.contentSnapshot().filterIsInstance<PageContent.Text>().firstOrNull { it.annotation.id == id }?.annotation
    ).also { activeTextEdit = it }
  }

  fun updateTextEdit(edit: DocumentTextEdit, annotation: TextAnnotation?, options: TextAnnotationOptions? = null) = withMutablePage(edit.context) { page ->
    requireContentMutationReady()
    if (activeTextEdit !== edit || !edit.active) throw cancelled()
    if (options != null) text.captureEditOptions(edit.context, edit.id, options)
    if (edit.current == annotation) return@withMutablePage
    edit.update(annotation)
    changed(DocumentChange.Text(page.id))
  }

  fun endTextEdit(id: Long? = null) {
    checkMainThread()
    val edit = activeTextEdit ?: return
    if (id != null && edit.id != id) return
    activeTextEdit = null
    edit.end()
    if (edit.baseline != edit.current) text.applyEdit(edit.context, edit.baseline, edit.current)
    changed(DocumentChange.EditEnded(edit))
    changed(DocumentChange.Text(edit.context.pageId))
  }
  private val inputs = PageInputCoordinator(context, artifacts)
  private val fallback = AndroidFallbackFontResolver(context)
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val queue = Mutex()
  private val admissions = Any()
  private val jobs = LinkedHashSet<Job>()
  private val observers = LinkedHashSet<(DocumentChange) -> Unit>()
  private val prepared = LinkedHashMap<String, PreparedPageContext>()
  private val outputs = LinkedHashSet<File>()
  private val retiringFiles = LinkedHashSet<File>()
  private enum class Lifecycle { ACTIVE, CLOSING, CLOSED }
  private var lifecycle = Lifecycle.ACTIVE
  private var closeResult: Deferred<Unit>? = null

  private var attachedViewer: String? = null

  fun claimViewer(id: String) = synchronized(admissions) {
    if (lifecycle != Lifecycle.ACTIVE) throw cancelled()
    if (attachedViewer != null && attachedViewer != id)
      throw PdfSessionException("document_already_attached", "Detach the existing viewer first")
    attachedViewer = id
  }

  fun releaseViewer(id: String) = synchronized(admissions) {
    if (attachedViewer == id) attachedViewer = null
  }

  /** The FIFO is shared by all clients. Cancellation retains an in-flight native queue slot. */
  fun <T> submit(operation: suspend () -> T): Deferred<T> = synchronized(admissions) {
    if (lifecycle != Lifecycle.ACTIVE) throw cancelled()
    enqueue(operation)
  }

  private fun <T> enqueue(operation: suspend () -> T): Deferred<T> {
    val job = scope.async(start = CoroutineStart.LAZY) { queue.withLock { operation() } }
    jobs += job
    job.invokeOnCompletion { synchronized(admissions) { jobs.remove(job) } }
    job.start()
    return job
  }

  fun observe(observer: (DocumentChange) -> Unit): AutoCloseable {
    checkMainThread()
    observers += observer
    return AutoCloseable { checkMainThread(); observers -= observer }
  }

  internal fun changed(change: DocumentChange) {
    checkMainThread()
    if (change == DocumentChange.StructuralWriteStarted) structuralBusy = true
    if (change == DocumentChange.StructuralReady || change == DocumentChange.Pages) structuralBusy = false
    observers.toList().forEach { it(change) }
  }

  private fun <T> withActiveCore(action: () -> T): T = onMain {
    synchronized(admissions) { if (lifecycle != Lifecycle.ACTIVE) throw cancelled() }
    action()
  }

  internal fun <T> withDocument(action: () -> T): T = withActiveCore {
    if (!coordinator.hasDocument) throw cancelled()
    action()
  }

  internal fun <T> withMutablePage(context: TextPageContext, action: (InkPageState) -> T): T = withDocument {
    if (context.generation != coordinator.generation) throw cancelled()
    action(coordinator.pageForId(context.pageId) ?: throw cancelled())
  }

  internal fun <T> withPage(context: TextPageContext, action: (DocumentPageMetadata) -> T): T =
    withMutablePage(context) { action(it.metadata()) }

  fun pageInfo(context: TextPageContext): PageInfo = withPage(context) { page ->
    state.pageInfo(checkNotNull(state.pageIndexForId(page.id)))
  }

  fun documentInfo(): DocumentState = withActiveCore { state.documentInfo() }

  fun getPageIdsByTag(tag: String): Array<String> = withActiveCore {
    validatePageTag(tag)
    coordinator.pageIdsByTag(tag)
  }

  private fun validatePageTag(tag: String) {
    if (tag.isEmpty()) throw PdfSessionException("invalid_page_tag", "Page tags must be nonempty strings")
  }

  suspend fun getPage(query: TaggedPageQuery): PreparedPageContext {
    validatePageTag(query.tag)
    val occurrence = query.index ?: 0.0
    validatePageIndex(occurrence)
    val index = if (occurrence <= Int.MAX_VALUE.toDouble()) coordinator.pageIndexByTag(query.tag, occurrence.toInt()) else null
    return getPage((index ?: throw PdfSessionException("page_not_found", "No page matches the requested tag and index")).toDouble())
  }

  fun commitInk(context: TextPageContext, outline: StrokeOutline) = withMutablePage(context) { page ->
    requireContentMutationReady()
    page.history.append(outline)
    changed(DocumentChange.Content(coordinator.generation, page.id, InkHistoryMutation.Appended(outline)))
  }

  private fun mutateHistory(pageId: String, operation: (InkPageState) -> InkHistoryMutation) = withDocument {
    requireContentMutationReady()
    endTextEdit()
    val page = coordinator.pageForId(pageId) ?: throw cancelled()
    val mutation = operation(page)
    if (mutation != InkHistoryMutation.NoOp) changed(DocumentChange.Content(coordinator.generation, pageId, mutation))
  }

  fun undo(pageId: String) = mutateHistory(pageId, coordinator::undoHistory)
  fun redo(pageId: String) = mutateHistory(pageId, coordinator::redoHistory)
  fun clearContent(pageId: String) = withDocument {
    mutateHistory(pageId, coordinator::clearHistory)
    changed(DocumentChange.InkCleared(pageId))
  }
  fun clearInk(pageId: String) = withDocument {
    mutateHistory(pageId, coordinator::clearInk)
    changed(DocumentChange.InkCleared(pageId))
  }

  fun requestSnapCandidates(generation: Long, pageIndex: Int,
                            completion: (Result<List<PdfiumHorizontalSnapCandidate>>) -> Unit) {
    checkMainThread()
    coordinator.horizontalSnapCandidates(generation, pageIndex, completion)
  }

  suspend fun open(uri: String, options: DocumentOpenOptions? = null): PdfSessionInfo {
    val pending = prepareOpen(uri, options)
    try { return commitOpen(pending) } finally { finishOpen(pending) }
  }

  suspend fun prepareOpen(uri: String, options: DocumentOpenOptions? = null): MutableDocumentCoordinator.PendingOpen {
    options?.tag?.let(::validatePageTag)
    prepared.clear()
    return coordinator.prepareOpen(
      fallbackFont = options?.androidFallbackFont,
      resolveFallbackFont = fallback::resolve,
      invalidatePrevious = { changed(DocumentChange.Opening) },
      tag = options?.tag,
      prepareSource = { destination ->
        val type = inputs.copyInto(uri, destination)
        if (type == PageType.IMAGE) {
          withContext(Dispatchers.IO) {
            val dimensions = options?.imagePageSize?.let { PdfPageDimensions(it.width, it.height) }
              ?: PdfPageDimensions(595.28, 841.89)
            val image = ImagePageEncoder.encode(destination, dimensions, options?.targetDpi, options?.jpegQuality)
            PdfiumPageAssembler.assemble(null,
              PdfiumAssemblyRequest(PdfiumAssemblyOperation.CREATE, appendInputs = listOf(image)), destination)
          }
        }
      },
    )
  }

  suspend fun <T> awaitOpen(
    pending: MutableDocumentCoordinator.PendingOpen,
    action: suspend () -> T,
  ): T = coordinator.awaitOpen(pending, action)

  suspend fun commitOpen(pending: MutableDocumentCoordinator.PendingOpen): PdfSessionInfo =
    coordinator.commitOpen(pending) { changed(DocumentChange.Opened) }

  suspend fun finishOpen(pending: MutableDocumentCoordinator.PendingOpen) = coordinator.finishOpen(pending)

  suspend fun getPage(index: Double): PreparedPageContext {
    val position = pageIndex(index)
    val page = coordinator.page(position)
    val generation = coordinator.generation
    prepared[page.id]?.let { return it }
    val analysis = awaitWorkerCancellable<PdfiumPreparedPageAnalysis> {
      coordinator.preparePageAnalysis(generation, position, it)
    }
    coordinator.ensureCurrent(generation)
    val context = PreparedPageContext(generation, page.id, analysis)
    coordinator.retainTextSourceGlyphs(page.id, context.analysis.glyphs)
    prepared[page.id] = context
    return context
  }

  suspend fun addPages(options: DocumentAddPagesOptions, imageDimensions: PdfPageDimensions): Int {
    options.tag?.let(::validatePageTag)
    checkNotNull(options.sources) { "Document imports require explicit sources" }
    val operation = coordinator.beginOperation()
    var staged = emptyList<StagedPageInput>()
    try {
      val generation = coordinator.generation
      staged = inputs.stage(options.sources)
      coordinator.ensureCurrent(generation)
      if (staged.isEmpty()) return 0
      endTextEdit()
      changed(DocumentChange.StructuralWriteStarted)
      val requests = withContext(Dispatchers.IO) {
        staged.map { source -> when (source.type) {
          PageType.PDF -> PdfiumAppendRequest(PageType.PDF, sourcePath = source.file.path)
          PageType.IMAGE -> ImagePageEncoder.encode(source.file, imageDimensions, options.targetDpi, options.jpegQuality)
        } }
      }
      coordinator.ensureCurrent(generation)
      val count = coordinator.pageCount
      withContext(NonCancellable) {
        coordinator.executeStructuralMutation(generation,
          PdfiumAssemblyRequest(PdfiumAssemblyOperation.APPEND,
            appendInputs = requests),
          candidateBuilder = { info -> coordinator.appendCandidate(info.pages.drop(count), options.tag) },
          notifyPublished = ::pagesChanged, fontFallback = coordinator.fallbackFont)
      }
      return coordinator.pageCount - count
    } finally { withContext(NonCancellable) { inputs.release(staged) }; coordinator.endOperation(operation); if (structuralBusy) changed(DocumentChange.StructuralReady) }
  }

  suspend fun removePage(index: Double) {
    val source = pageIndex(index)
    if (coordinator.pageCount == 1) throw PdfSessionException("last_page_required", "The document must retain one page")
    structural(PdfiumAssemblyRequest(PdfiumAssemblyOperation.REMOVE, pageIndex = source)) { coordinator.removePageCandidate(source) }
  }

  suspend fun movePage(from: Double, to: Double) {
    val source = pageIndex(from)
    val destination = pageIndex(to)
    if (source == destination) return
    structural(PdfiumAssemblyRequest(PdfiumAssemblyOperation.MOVE, pageIndex = source, destinationIndex = destination)) {
      coordinator.movePageCandidate(source, destination)
    }
  }

  private suspend fun structural(request: PdfiumAssemblyRequest, candidate: () -> MutableDocumentCoordinator.StructuralCandidate) {
    val operation = coordinator.beginOperation()
    try {
      val generation = coordinator.generation
      endTextEdit()
      changed(DocumentChange.StructuralWriteStarted)
      coordinator.ensureCurrent(generation)
      withContext(NonCancellable) {
        coordinator.executeStructuralMutation(generation, request, candidateBuilder = { candidate() },
          notifyPublished = ::pagesChanged)
      }
    } finally { coordinator.endOperation(operation); if (structuralBusy) changed(DocumentChange.StructuralReady) }
  }

  fun rotatePage(index: Double, degrees: Double) {
    val page = coordinator.page(pageIndex(index))
    if (degrees != 90.0 && degrees != 180.0 && degrees != 270.0)
      throw PdfSessionException("invalid_page_rotation", "Use 90, 180, or 270 degrees")
    val operation = coordinator.beginOperation()
    try {
      val generation = coordinator.generation
      endTextEdit()
      changed(DocumentChange.StructuralWriteStarted)
      coordinator.ensureCurrent(generation)
      val dimensions = PageCoordinates(page.dimensions).withRotation((page.dimensions.rotation + degrees.toInt() / 90) % 4)
      val candidate = coordinator.rotatePageCandidate(page.id, dimensions)
      coordinator.installCandidate(coordinator.sourcePath, candidate.pages)
      pagesChanged()
    } finally { coordinator.endOperation(operation); if (structuralBusy) changed(DocumentChange.StructuralReady) }
  }

  private fun pagesChanged() {
    prepared.keys.removeAll { coordinator.pageForId(it) == null }
    changed(DocumentChange.Pages)
  }

  suspend fun finalize(): String {
    endTextEdit()
    val operation = coordinator.beginOperation()
    var output: File? = null
    try {
      val snapshot = coordinator.captureExport()
      output = File(snapshot.outputPath)
      val result = awaitWorker<String> { coordinator.exportSession(snapshot, it) }
      coordinator.ensureCurrent(snapshot.generation)
      if (exportOwnership == ExportOwnership.DOCUMENT) outputs += output
      return android.net.Uri.fromFile(File(result)).toString()
    } catch (error: Throwable) {
      output?.let { withContext(NonCancellable + Dispatchers.IO) { artifacts.deleteExact(it) } }
      throw error
    } finally { coordinator.endOperation(operation); if (structuralBusy) changed(DocumentChange.StructuralReady) }
  }

  /** Reusable client reset. The viewer can open another document after this completes. */
  suspend fun clearDocument() {
    prepared.clear()
    awaitWorker<Unit> { completion ->
      coordinator.closeDocument(completion)
      changed(DocumentChange.Cleared)
    }
    fonts.close()
  }

  /** Invalidate now, then serialize cleanup behind native work before admitting replacement. */
  fun clearImmediately(): Deferred<Unit> = onMain {
    synchronized(admissions) {
      if (lifecycle != Lifecycle.ACTIVE) throw cancelled()
      jobs.toList().forEach { it.cancel() }
    }
    prepared.clear()
    inputs.cancelPending()
    val cleared = CompletableDeferred<Unit>()
    coordinator.closeDocument { result -> result.fold({ cleared.complete(Unit) }, { cleared.completeExceptionally(it) }) }
    changed(DocumentChange.Cleared)
    synchronized(admissions) { enqueue {
      withContext(NonCancellable) { cleared.await() }
      fonts.close()
    } }
  }

  fun close(cancelPending: Boolean = false): Deferred<Unit> = onMain {
    synchronized(admissions) {
      closeResult?.let { return@synchronized it }
      endTextEdit()
      changed(DocumentChange.WillClose)
      lifecycle = Lifecycle.CLOSING
      if (cancelPending) {
        retiringFiles += coordinator.workingFiles() + listOfNotNull(coordinator.currentWorkingFile())
        jobs.toList().forEach { it.cancel() }
        coordinator.dispose()
      }
      enqueue {
        val files = coordinator.workingFiles() + listOfNotNull(coordinator.currentWorkingFile()) + outputs + retiringFiles
        prepared.clear()
        changed(DocumentChange.Cleared)
        observers.clear()
        inputs.close()
        coordinator.dispose()
        awaitWorker<Unit> { coordinator.sessionWorker.closeAwaited(files, artifacts::deleteExact, it) }
        fonts.close()
        synchronized(admissions) { lifecycle = Lifecycle.CLOSED }
      }.also { result ->
        closeResult = result
        result.invokeOnCompletion { scope.cancel() }
      }
    }
  }

  private fun pageIndex(index: Double): Int {
    if (!coordinator.hasDocument) throw cancelled()
    validatePageIndex(index)
    if (index >= coordinator.pageCount)
      throw PdfSessionException("page_not_found", "The page index is outside the document")
    return index.toInt()
  }

  private fun validatePageIndex(index: Double) {
    if (!index.isFinite() || index < 0 || index % 1.0 != 0.0)
      throw PdfSessionException("invalid_page_index", "The page index must be a non-negative integer")
  }

  private suspend fun <T> awaitWorker(start: ((Result<T>) -> Unit) -> Unit): T =
    withContext(NonCancellable) {
      suspendCancellableCoroutine { continuation ->
        start { result -> result.fold({ continuation.resume(it) }, { continuation.resumeWithException(it) }) }
      }
    }

  private suspend fun <T> awaitWorkerCancellable(start: ((Result<T>) -> Unit) -> Unit): T =
    suspendCancellableCoroutine { continuation ->
      start { result -> result.fold({ continuation.resume(it) }, { continuation.resumeWithException(it) }) }
    }

  internal fun <T> onMain(action: () -> T): T {
    if (Looper.myLooper() == Looper.getMainLooper()) return action()
    val latch = CountDownLatch(1)
    var result: Result<T>? = null
    if (!Handler(Looper.getMainLooper()).post { result = runCatching(action); latch.countDown() }) throw cancelled()
    try {
      latch.await()
    } catch (error: InterruptedException) {
      Thread.currentThread().interrupt()
      throw cancelled()
    }
    return checkNotNull(result).getOrThrow()
  }

  private fun checkMainThread() { check(Looper.myLooper() == Looper.getMainLooper()) }
  private fun cancelled() = PdfSessionException("operation_cancelled", "The document is closed or was replaced")
}
