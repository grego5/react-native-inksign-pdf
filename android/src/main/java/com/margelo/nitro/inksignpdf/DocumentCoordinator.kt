package com.margelo.nitro.inksignpdf

import java.util.LinkedHashSet
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** UI-thread-owned coordinator for one published mutable PDF document. */
internal class MutableDocumentCoordinator(
  sourcePath: String = "",
  generation: Long = 0L,
  pages: List<PdfPageDimensions> = emptyList(),
  internal val sessionWorker: PdfSessionWorker,
  private val artifactPolicy: DocumentArtifactPolicy,
) {
  private val mutablePages: MutableList<InkPageState> = pages.map { dimensions ->
    InkPageState(PageRecord.newId(), dimensions)
  }.toMutableList()
  private var activePageId: String? = mutablePages.firstOrNull()?.id
  private var generationValue = generation
  private var latestOpenAttemptId: Long? = null
  private val openStateLock = Any()
  private var operationSequence = 0L
  private var activeOperation: Long? = null
  private val workingFiles = LinkedHashSet<java.io.File>()
  private var disposed = false
  var fallbackFont: PdfFallbackFont? = null
  var structuralDirty: Boolean = false
    private set

  init {
    if (mutablePages.isNotEmpty()) {
      require(sourcePath.isNotEmpty())
      require(activePageId != null)
    } else {
      require(sourcePath.isEmpty())
    }
  }

  var sourcePath: String = sourcePath
    private set

  val generation: Long
    get() = generationValue

  /** Immutable view of the published page records. Page histories remain owned by this coordinator. */
  val pages: List<InkPageState>
    get() = mutablePages.toList()

  val hasDocument: Boolean
    get() = mutablePages.isNotEmpty()

  val activePageIndex: Int
    get() = mutablePages.indexOfFirst { it.id == activePageId }.also { index ->
      check(index >= 0) { "Active page is not present in the document" }
    }

  val pageCount: Int
    get() = mutablePages.size

  fun page(index: Int): InkPageState {
    require(index in mutablePages.indices)
    return mutablePages[index]
  }

  fun setActivePage(index: Int) {
    require(index in mutablePages.indices)
    activePageId = mutablePages[index].id
  }

  fun installCandidate(
    candidatePath: String,
    candidatePages: List<InkPageState>,
    candidateActivePageId: String,
  ) {
    require(candidatePath.isNotEmpty())
    require(candidatePages.isNotEmpty())
    require(candidatePages.any { it.id == candidateActivePageId })
    sourcePath = candidatePath
    mutablePages.clear()
    mutablePages.addAll(candidatePages)
    activePageId = candidateActivePageId
    structuralDirty = true
  }

  data class StructuralCandidate(
    val pages: List<InkPageState>,
    val activePageId: String,
  )

  fun appendCandidate(dimensions: List<PdfPageDimensions>): StructuralCandidate {
    require(dimensions.isNotEmpty())
    val appended = dimensions.map { InkPageState(PageRecord.newId(), it) }
    return StructuralCandidate(mutablePages.toList() + appended, appended.first().id)
  }

  fun removeActiveCandidate(): StructuralCandidate {
    check(pageCount > 1) { "The document must retain one page" }
    val next = mutablePages.toMutableList().also { it.removeAt(activePageIndex) }
    val targetIndex = activePageIndex.coerceAtMost(next.lastIndex)
    return StructuralCandidate(next, next[targetIndex].id)
  }

  fun moveActiveCandidate(destination: Int): StructuralCandidate {
    require(destination in mutablePages.indices)
    val source = activePageIndex
    if (source == destination) return StructuralCandidate(mutablePages.toList(), checkNotNull(activePageId))
    val next = mutablePages.toMutableList().also {
      val moved = it.removeAt(source)
      it.add(destination, moved)
    }
    return StructuralCandidate(next, checkNotNull(activePageId))
  }

  fun markStructuralDirty() { structuralDirty = true }

  fun markStructuralClean() { structuralDirty = false }

  fun pageRecords(): List<PageRecord> = pages.map { page -> PageRecord(page.id, page.dimensions) }

  fun activePageId(): String = checkNotNull(activePageId)

  fun sessionInfo(): PdfSessionInfo = PdfSessionInfo(
    sourcePath = sourcePath,
    pages = pages.map { it.dimensions },
    generation = generation,
  )

  data class Snapshot(
    val sourcePath: String,
    val generation: Long,
    val pages: List<PageSnapshot>,
    val activePageIndex: Int,
    val activePageId: String,
    val structuralDirty: Boolean,
  )

  data class PageSnapshot(
    val id: String,
    val dimensions: PdfPageDimensions,
    val content: List<PageContent>,
  )

  fun pageSnapshot(index: Int): PageSnapshot {
    val page = page(index)
    return PageSnapshot(page.id, page.dimensions, page.history.contentSnapshot())
  }

  fun pageHistoryRevision(index: Int): Long = page(index).history.revision
  fun activeHistoryRevision(): Long = activeHistory().revision
  fun activeHistoryState(): InkState = activeHistory().state()
  fun isDirty(): Boolean = structuralDirty || mutablePages.any { it.history.state().isDirty }

  fun activatePage(index: Int): PageSnapshot {
    setActivePage(index)
    return pageSnapshot(index)
  }

  fun appendActiveInk(outline: StrokeOutline) = activeHistory().append(outline)
  fun appendActiveText(annotation: TextAnnotation) = activeHistory().appendText(annotation)
  fun replaceActiveText(before: TextAnnotation, after: TextAnnotation) =
    activeHistory().replaceText(before, after)
  fun removeActiveText(annotation: TextAnnotation) = activeHistory().removeTextAnnotation(annotation)
  fun undoActiveHistory(): InkHistoryMutation = activeHistory().undoMutation()
  fun redoActiveHistory(): InkHistoryMutation = activeHistory().redoMutation()
  fun clearActiveHistory(): InkHistoryMutation = activeHistory().clearMutation()
  fun resetHistories() = mutablePages.forEach { it.history.reset() }

  fun completedPagesSnapshot(): List<PdfPageContentSnapshot> =
    mutablePages.mapIndexed { pageIndex, page ->
      PdfPageContentSnapshot(pageIndex, page.dimensions, page.history.contentSnapshot())
    }

  fun captureExport(color: Int): PdfExportSnapshot {
    val document = snapshot()
    return PdfExportSnapshot(
      sourcePath = document.sourcePath,
      outputPath = artifactPolicy.allocateSignedOutput().path,
      pages = document.pages.mapIndexed { pageIndex, page ->
        PdfPageExportSnapshot(
          pageIndex = pageIndex,
          dimensions = page.dimensions,
          strokes = page.content.mapNotNull { it.inkOutlineOrNull() },
          textAnnotations = page.content.mapNotNull { it.textAnnotationOrNull() },
        )
      },
      generation = document.generation,
      color = color,
    )
  }

  fun snapshot(): Snapshot {
    check(hasDocument) { "A document is not published" }
    return Snapshot(
      sourcePath = sourcePath,
      generation = generation,
      pages = pages.map { page -> PageSnapshot(page.id, page.dimensions, page.history.contentSnapshot()) },
      activePageIndex = activePageIndex,
      activePageId = activePageId(),
      structuralDirty = structuralDirty,
    )
  }

  fun presentationSnapshot(): Snapshot = snapshot()

  private data class OpenRequest(
    val attemptId: Long,
    val fallbackFont: PdfFallbackFont?,
    val workingFile: java.io.File,
    val operationID: Long,
  )

  private data class CommittedOpenState(
    val pages: List<InkPageState>,
    val activePageId: String?,
    val sourcePath: String,
    val generation: Long,
    val structuralDirty: Boolean,
    val fallbackFont: PdfFallbackFont?,
  )

  suspend fun <P, T> executeOpen(
    sourcePath: String,
    fallbackFont: PdfFallbackFont?,
    preparePresentation: (PdfSessionInfo) -> P,
    installPresentation: (P) -> T,
    restorePresentation: () -> Unit = {},
  ): T {
    val request = beginOpen(fallbackFont)
    var committed = false
    var pendingWorkerCommit: CompletableDeferred<Result<Unit>>? = null
    try {
      withContext(Dispatchers.IO) {
        val source = try {
          java.io.File(sourcePath).canonicalFile
        } catch (error: Exception) {
          throw PdfSessionException("invalid_source_path", "Unable to resolve the PDF path", error)
        }
        if (!source.isFile || !source.canRead()) {
          throw PdfSessionException("invalid_source_path", "Unable to read the PDF")
        }
        source.copyTo(request.workingFile, overwrite = true)
      }
      val info = awaitWorkerResult(request.attemptId) { completion ->
        sessionWorker.prepareOpen(
          request.attemptId,
          request.workingFile.path,
          request.fallbackFont,
          completion,
        )
      }
      ensureCurrentOpen(request.attemptId)
      if (info.generation != request.attemptId) throw cancelled()
      validateOpenCandidate(info)
      val presentation = preparePresentation(info)
      ensureCurrentOpen(request.attemptId)

      val workerCommit = CompletableDeferred<Result<Unit>>()
      val gate = OpenCommitGate()
      val committedPresentation = synchronized(openStateLock) {
        ensureCurrentOpen(request.attemptId)
        if (!sessionWorker.commitPreparedOpen(request.attemptId, gate, workerCommit::complete)) {
          throw cancelled()
        }
        pendingWorkerCommit = workerCommit
        val previousState = captureCommittedOpenState()
        try {
          val previousWorkingFile = publishOpenCandidate(request, info)
          val value = installPresentation(presentation)
          gate.accept()
          committed = true
          previousWorkingFile to value
        } catch (error: Throwable) {
          restoreCommittedOpenState(previousState)
          runCatching { restorePresentation() }
          gate.reject()
          throw error
        }
      }
      workerCommit.await().getOrThrow()
      val (previousWorkingFile, value) = committedPresentation
      previousWorkingFile?.let { previous -> runCatching { retireWorkingFile(previous) } }
      return value
    } finally {
      if (!committed) {
        withContext(NonCancellable) { pendingWorkerCommit?.await() }
        runCatching {
          awaitWorkerResult<Unit>(request.attemptId) { completion ->
            sessionWorker.discardPreparedOpen(request.attemptId, completion)
          }
        }
        retireWorkingFile(request.workingFile)
      }
      endOperation(request.operationID)
    }
  }

  private fun beginOpen(fallbackFont: PdfFallbackFont?): OpenRequest {
    return synchronized(openStateLock) {
      check(!disposed) { "PDF coordinator was disposed" }
      val workingFile = artifactPolicy.allocateWorkingPdf()
      try {
        val attemptId = sessionWorker.reserveOpenAttemptId(generationValue)
        latestOpenAttemptId = attemptId
        activeOperation = nextOperation()
        trackWorkingFile(workingFile)
        currentWorkingFile()?.let(::trackWorkingFile)
        OpenRequest(attemptId, fallbackFont, workingFile, checkNotNull(activeOperation))
      } catch (error: Throwable) {
        artifactPolicy.deleteExact(workingFile)
        throw error
      }
    }
  }

  private fun ensureCurrentOpen(attemptId: Long) {
    synchronized(openStateLock) {
      if (disposed || latestOpenAttemptId != attemptId) throw cancelled()
    }
  }

  private fun validateOpenCandidate(info: PdfSessionInfo) {
    if (info.pages.isEmpty() || info.pages.any {
        !it.width.isFinite() || it.width <= 0.0 || !it.height.isFinite() || it.height <= 0.0
      }
    ) {
      throw PdfSessionException("pdf_load_failed", "The opened PDF contains invalid page dimensions")
    }
  }

  private fun publishOpenCandidate(request: OpenRequest, info: PdfSessionInfo): java.io.File? {
    ensureNotDisposed()
    ensureCurrentOpen(request.attemptId)
    check(info.generation == request.attemptId)
    val previous = currentWorkingFile()
    mutablePages.clear()
    mutablePages.addAll(info.pages.map { InkPageState(PageRecord.newId(), it) })
    activePageId = mutablePages.first().id
    sourcePath = request.workingFile.path
    generationValue = request.attemptId
    markStructuralClean()
    fallbackFont = request.fallbackFont
    untrackWorkingFile(request.workingFile)
    return previous
  }

  private fun captureCommittedOpenState() = CommittedOpenState(
    pages = mutablePages.toList(),
    activePageId = activePageId,
    sourcePath = sourcePath,
    generation = generationValue,
    structuralDirty = structuralDirty,
    fallbackFont = fallbackFont,
  )

  private fun restoreCommittedOpenState(state: CommittedOpenState) {
    mutablePages.clear()
    mutablePages.addAll(state.pages)
    activePageId = state.activePageId
    sourcePath = state.sourcePath
    generationValue = state.generation
    structuralDirty = state.structuralDirty
    fallbackFont = state.fallbackFont
  }

  fun beginOperation(requireDocument: Boolean = true): Long {
    check(!disposed) { "PDF coordinator was disposed" }
    if (activeOperation != null) {
      throw PdfSessionException("operation_in_progress", "Another document operation is already active")
    }
    if (requireDocument) check(hasDocument) { "A PDF must be opened before changing pages" }
    return nextOperation()
  }

  fun beginOperation(preflight: () -> Unit): Long = beginOperation(requireDocument = true, preflight = preflight)

  fun beginOperation(requireDocument: Boolean, preflight: () -> Unit): Long {
    val operation = beginOperation(requireDocument)
    try {
      preflight()
      return operation
    } catch (error: Throwable) {
      endOperation(operation)
      throw error
    }
  }

  fun endOperation(operation: Long) { if (activeOperation == operation) activeOperation = null }

  fun ensureCurrent(expectedGeneration: Long) {
    if (disposed || generation != expectedGeneration) throw cancelled()
  }

  fun trackWorkingFile(file: java.io.File) { workingFiles += file }
  fun untrackWorkingFile(file: java.io.File) { workingFiles.remove(file) }
  fun retireWorkingFile(file: java.io.File) {
    untrackWorkingFile(file)
    artifactPolicy.deleteExact(file)
  }
  fun currentWorkingFile(): java.io.File? = sourcePath.takeIf { it.isNotEmpty() }?.let { java.io.File(it) }
  fun workingFiles(): Set<java.io.File> = workingFiles.toSet()

  fun allocateMutationCandidate(): java.io.File = artifactPolicy.allocateMutationScratch().also(::trackWorkingFile)

  fun prepareMutation(
    candidate: java.io.File,
    generation: Long,
    request: PdfiumAssemblyRequest,
    fontFallback: PdfFallbackFont? = fallbackFont,
    retireCandidate: (java.io.File) -> Unit,
    completion: (Result<PdfSessionInfo>) -> Unit,
  ) {
    ensureCurrent(generation)
    sessionWorker.prepareMutation(
      workingPath = if (request.operation == PdfiumAssemblyOperation.CREATE) {
        check(!hasDocument && currentWorkingFile() == null) { "CREATE requires an empty coordinator" }
        null
      } else {
        checkNotNull(currentWorkingFile()).path
      },
      candidatePath = candidate.path,
      generation = generation,
      request = request,
      fallbackFont = fontFallback,
      retireCandidate = retireCandidate,
      completion = completion,
    )
  }

  fun commitPreparedMutation(candidate: java.io.File, generation: Long, completion: (Result<Unit>) -> Unit) {
    sessionWorker.commitPreparedMutation(candidate.path, generation, completion)
  }

  fun discardPreparedMutation(candidate: java.io.File, retireCandidate: (java.io.File) -> Unit) {
    untrackWorkingFile(candidate)
    sessionWorker.discardPreparedMutation(candidate.path, retireCandidate)
  }

  fun cancel(generation: Long) { sessionWorker.cancel(generation) }

  suspend fun <T> executeStructuralMutation(
    generation: Long,
    request: PdfiumAssemblyRequest,
    candidateBuilder: (PdfSessionInfo) -> StructuralCandidate,
    validate: (PdfSessionInfo, StructuralCandidate) -> Unit,
    present: () -> T,
    fontFallback: PdfFallbackFont? = fallbackFont,
  ): T {
    ensureCurrent(generation)
    val candidate = allocateMutationCandidate()
    val policy = artifactPolicy
    var published = false
    try {
      val info = awaitWorkerResult(generation) { completion ->
        prepareMutation(
          candidate,
          generation,
          request,
          fontFallback,
          policy::deleteExact,
          completion,
        )
      }
      ensureCurrent(generation)
      val pageCandidate = candidateBuilder(info)
      validateCandidateAggregate(info, pageCandidate)
      validate(info, pageCandidate)
      awaitWorkerResult<Unit>(generation) { completion ->
        commitPreparedMutation(candidate, generation, completion)
      }
      ensureCurrent(generation)
      val oldWorking = publishStructuralCandidate(info, pageCandidate)
      fallbackFont = fontFallback
      published = true
      untrackWorkingFile(candidate)
      oldWorking?.let(policy::deleteExact)
      return present()
    } finally {
      if (!published) discardPreparedMutation(candidate, policy::deleteExact)
    }
  }

  fun exportSession(snapshot: PdfExportSnapshot, completion: (Result<String>) -> Unit) {
    sessionWorker.export(snapshot, artifactPolicy, completion)
  }

  fun closeSession(outputs: Collection<java.io.File>, retireOutput: (java.io.File) -> Unit) {
    sessionWorker.close(outputs, retireOutput)
  }

  fun publishStructuralCandidate(info: PdfSessionInfo, candidate: StructuralCandidate): java.io.File? {
    ensureNotDisposed()
    require(info.generation == generation)
    require(info.pageCount == candidate.pages.size)
    val previous = currentWorkingFile()
    installCandidate(info.sourcePath, candidate.pages, candidate.activePageId)
    untrackWorkingFile(java.io.File(info.sourcePath))
    return previous
  }

  fun clearPublishedDocument() {
    mutablePages.clear()
    activePageId = null
    sourcePath = ""
    markStructuralClean()
  }

  fun dispose() {
    if (disposed) return
    disposed = true
    latestOpenAttemptId = null
    sessionWorker.cancel(generationValue)
    generationValue += 1L
    activeOperation = null
    clearPublishedDocument()
  }

  private fun nextOperation(): Long {
    operationSequence += 1L
    activeOperation = operationSequence
    return operationSequence
  }

  private fun ensureNotDisposed() { if (disposed) throw cancelled() }
  private fun activeHistory(): InkHistory = page(activePageIndex).history

  internal fun validateCandidateAggregate(info: PdfSessionInfo, candidate: StructuralCandidate) {
    if (info.pages.size != candidate.pages.size ||
      info.pages.indices.any { index -> info.pages[index] != candidate.pages[index].dimensions }
    ) {
      throw PdfSessionException(
        "pdf_mutation_failed",
        "The assembled PDF page metadata does not match the structural candidate",
      )
    }
  }

  private suspend fun <T> awaitWorkerResult(
    generation: Long,
    start: (((Result<T>) -> Unit) -> Unit),
  ): T = suspendCancellableCoroutine { continuation ->
    start { result ->
      result.fold(
        onSuccess = { value -> continuation.resume(value) },
        onFailure = { error -> continuation.resumeWithException(error) },
      )
    }
    continuation.invokeOnCancellation { cancel(generation) }
  }

  private fun cancelled(): PdfSessionException = PdfSessionException(
    "operation_cancelled",
    "PDF view was disposed or the open was superseded",
  )
}
