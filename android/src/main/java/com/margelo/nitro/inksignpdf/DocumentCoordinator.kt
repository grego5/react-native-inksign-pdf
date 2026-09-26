package com.margelo.nitro.inksignpdf

import java.util.LinkedHashSet
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.selects.select
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
  private var mutablePages: MutableList<InkPageState> = pages.map { dimensions ->
    InkPageState(PageRecord.newId(), dimensions)
  }.toMutableList()
  private var activePageId: String? = mutablePages.firstOrNull()?.id
  private var generationValue = generation
  private var activeOpenRequest: OpenRequest? = null
  private val openStateLock = Any()
  // Tracks arrival order, including requests queued behind a handoff.
  // Worker attempt IDs are reserved only after a request is admitted.
  private var openRequestSequence = 0L
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
    check(destination in mutablePages.indices) { "Admitted move destination is outside the document" }
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
    val superseded: CompletableDeferred<Unit> = CompletableDeferred(),
    // Null before handoff, then completed when newer opens may proceed.
    var handoffFinished: CompletableDeferred<Unit>? = null,
  )

  private data class PreparedOpenCandidate(
    val pages: MutableList<InkPageState>,
    val activePageId: String,
    val sourcePath: String,
    val generation: Long,
    val fallbackFont: PdfFallbackFont?,
    val workingFile: java.io.File,
    val previousWorkingFile: java.io.File?,
  )

  /** Prepares offscreen, then commits worker, model, and viewer state in one handoff. */
  suspend fun <P, T> executeOpen(
    sourcePath: String,
    fallbackFont: PdfFallbackFont?,
    awaitContainerSize: suspend () -> ViewportSize,
    preparePresentation: (PdfSessionInfo, ViewportSize) -> P,
    beginHandoff: () -> Unit = {},
    publishPresentation: (P) -> T,
    notifyPublished: (T) -> Unit = {},
    abortHandoff: () -> Unit = {},
  ): T {
    val request = beginOpen(fallbackFont)
    var committed = false
    try {
      val info = awaitUnlessSuperseded(request) {
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
        val candidate = awaitWorkerResult(request.attemptId) { completion ->
          sessionWorker.prepareOpen(
            request.attemptId,
            request.workingFile.path,
            request.fallbackFont,
            completion,
          )
        }
        ensureCurrentOpen(request.attemptId)
        if (candidate.generation != request.attemptId) throw cancelled()
        candidate
      }
      val containerSize = awaitUnlessSuperseded(request, awaitContainerSize)
      ensureCurrentOpen(request.attemptId)
      val presentation = preparePresentation(info, containerSize)
      val preparedCandidate = prepareOpenCandidate(request, info)
      synchronized(openStateLock) {
        ensureCurrentOpen(request.attemptId)
        request.handoffFinished = CompletableDeferred()
      }
      beginHandoff()
      currentCoroutineContext().ensureActive()
      ensureCurrentOpen(request.attemptId)

      // A request arriving after this point waits for the handoff to finish.
      val (previousWorkingFile, value) = withContext(NonCancellable) {
        awaitWorkerResult<Unit>(request.attemptId) { completion ->
          sessionWorker.commitPreparedOpen(request.attemptId, completion)
        }
        if (disposed) throw cancelled()
        val publication = synchronized(openStateLock) {
          ensureCurrentOpen(request.attemptId)
          publishOpenCandidate(preparedCandidate)
          val previousWorkingFile = preparedCandidate.previousWorkingFile
          val value = publishPresentation(presentation)
          committed = true
          previousWorkingFile to value
        }
        runCatching { notifyPublished(publication.second) }
        runCatching {
          awaitWorkerResult<Unit>(request.attemptId) { completion ->
            sessionWorker.retireReplacedOpenSession(request.attemptId, completion)
          }
        }
        publication.first?.let { previous -> runCatching { retireWorkingFile(previous) } }
        publication
      }
      return value
    } catch (error: Throwable) {
      val shouldAbortHandoff = synchronized(openStateLock) {
        !committed && !disposed &&
          activeOpenRequest?.attemptId == request.attemptId && request.handoffFinished != null
      }
      if (shouldAbortHandoff) {
        runCatching { abortHandoff() }.exceptionOrNull()?.let(error::addSuppressed)
      }
      throw error
    } finally {
      try {
        if (!committed) {
          withContext(NonCancellable) {
            runCatching {
              awaitWorkerResult<Unit>(request.attemptId) { completion ->
                sessionWorker.discardPreparedOpen(request.attemptId, completion)
              }
            }
            retireWorkingFile(request.workingFile)
          }
        }
      } finally {
        endOperation(request.operationID)
      }
    }
  }

  private suspend fun beginOpen(fallbackFont: PdfFallbackFont?): OpenRequest {
    val requestSequence = synchronized(openStateLock) {
      if (disposed) throw cancelled()
      openRequestSequence += 1L
      openRequestSequence
    }
    while (true) {
      var waitForHandoff: CompletableDeferred<Unit>? = null
      val request = synchronized(openStateLock) {
        if (disposed) throw cancelled()
        if (requestSequence != openRequestSequence) throw cancelled()
        val active = activeOpenRequest
        val handoffFinished = active?.handoffFinished
        if (handoffFinished != null) {
          waitForHandoff = handoffFinished
          null
        } else {
          val workingFile = artifactPolicy.allocateWorkingPdf()
          try {
            val attemptId = sessionWorker.reserveOpenAttemptId(generationValue)
            active?.superseded?.complete(Unit)
            val operationID = nextOperation()
            trackWorkingFile(workingFile)
            currentWorkingFile()?.let(::trackWorkingFile)
            OpenRequest(attemptId, fallbackFont, workingFile, operationID).also {
              activeOpenRequest = it
            }
          } catch (error: Throwable) {
            artifactPolicy.deleteExact(workingFile)
            throw error
          }
        }
      }
      if (request != null) return request
      checkNotNull(waitForHandoff).await()
    }
  }

  private suspend fun <T> awaitUnlessSuperseded(
    request: OpenRequest,
    action: suspend () -> T,
  ): T = coroutineScope {
    val work = async { action() }
    select {
      work.onAwait { it }
      request.superseded.onAwait {
        work.cancel()
        throw cancelled()
      }
    }
  }

  private fun ensureCurrentOpen(attemptId: Long) {
    synchronized(openStateLock) {
      if (disposed || activeOpenRequest?.attemptId != attemptId) throw cancelled()
    }
  }

  private fun prepareOpenCandidate(request: OpenRequest, info: PdfSessionInfo): PreparedOpenCandidate {
    val pages = info.pages.map { dimensions ->
      InkPageState(PageRecord.newId(), dimensions)
    }.toMutableList()
    return PreparedOpenCandidate(
      pages = pages,
      activePageId = pages.first().id,
      sourcePath = request.workingFile.path,
      generation = request.attemptId,
      fallbackFont = request.fallbackFont,
      workingFile = request.workingFile,
      previousWorkingFile = currentWorkingFile(),
    )
  }

  private fun publishOpenCandidate(candidate: PreparedOpenCandidate) {
    mutablePages = candidate.pages
    activePageId = candidate.activePageId
    sourcePath = candidate.sourcePath
    generationValue = candidate.generation
    markStructuralClean()
    fallbackFont = candidate.fallbackFont
    untrackWorkingFile(candidate.workingFile)
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

  fun endOperation(operation: Long) {
    synchronized(openStateLock) {
      if (activeOperation == operation) activeOperation = null
      if (activeOpenRequest?.operationID == operation) {
        activeOpenRequest?.handoffFinished?.complete(Unit)
        activeOpenRequest = null
      }
    }
  }

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

  fun horizontalSnapCandidates(
    generation: Long,
    pageIndex: Int,
    completion: (Result<List<PdfiumHorizontalSnapCandidate>>) -> Unit,
  ) = sessionWorker.horizontalSnapCandidates(generation, pageIndex, completion)

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
    activeOpenRequest?.superseded?.complete(Unit)
    activeOpenRequest?.handoffFinished?.complete(Unit)
    activeOpenRequest = null
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
