package com.margelo.nitro.inksignpdf

import java.util.LinkedHashSet
import kotlinx.coroutines.Dispatchers
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
    val generation: Long,
    val fallbackFont: PdfFallbackFont?,
    val workingFile: java.io.File,
    val previousWorkingFile: java.io.File?,
    val operationID: Long,
  )

  suspend fun <T> executeOpen(
    sourcePath: String,
    fallbackFont: PdfFallbackFont?,
    resetPresentation: () -> Unit,
    installPresentation: () -> T,
  ): T {
    val request = beginOpen(fallbackFont)
    var statePublished = false
    try {
      resetPresentation()
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
      val info = awaitWorkerResult(request.generation) { completion ->
        replaceSession(request.workingFile.path, request.generation, request.fallbackFont, completion)
      }
      ensureCurrent(request.generation)
      if (info.generation != request.generation) throw cancelled()
      publishOpen(info)
      this.fallbackFont = request.fallbackFont
      statePublished = true
      return installPresentation()
    } finally {
      if (!statePublished) retireWorkingFile(request.workingFile)
      request.previousWorkingFile?.let(::retireWorkingFile)
      endOperation(request.operationID)
    }
  }

  private fun beginOpen(fallbackFont: PdfFallbackFont?): OpenRequest {
    check(!disposed) { "PDF coordinator was disposed" }
    val previousWorkingFile = currentWorkingFile()
    sessionWorker.cancel(generationValue)
    generationValue += 1L
    activeOperation = nextOperation()
    mutablePages.clear()
    activePageId = null
    sourcePath = ""
    structuralDirty = false
    this.fallbackFont = null
    val workingFile = try {
      artifactPolicy.allocateWorkingPdf()
    } catch (error: Throwable) {
      activeOperation = null
      throw error
    }
    trackWorkingFile(workingFile)
    previousWorkingFile?.let(::trackWorkingFile)
    return OpenRequest(generation, fallbackFont, workingFile, previousWorkingFile, checkNotNull(activeOperation))
  }

  fun beginOperation(): Long {
    check(!disposed) { "PDF coordinator was disposed" }
    if (activeOperation != null) {
      throw PdfSessionException("operation_in_progress", "Another document operation is already active")
    }
    check(hasDocument) { "A PDF must be opened before changing pages" }
    return nextOperation()
  }

  fun beginOperation(preflight: () -> Unit): Long {
    val operation = beginOperation()
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
  fun currentWorkingFile(): java.io.File? = sourcePath.takeIf { it.isNotEmpty() }?.let(::java.io.File)
  fun workingFiles(): Set<java.io.File> = workingFiles.toSet()

  fun allocateMutationCandidate(): java.io.File = artifactPolicy.allocateMutationScratch().also(::trackWorkingFile)

  fun prepareMutation(
    candidate: java.io.File,
    generation: Long,
    request: PdfiumAssemblyRequest,
    retireCandidate: (java.io.File) -> Unit,
    completion: (Result<PdfSessionInfo>) -> Unit,
  ) {
    ensureCurrent(generation)
    sessionWorker.prepareMutation(
      workingPath = checkNotNull(currentWorkingFile()).path,
      candidatePath = candidate.path,
      generation = generation,
      request = request,
      fallbackFont = fallbackFont,
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
  ): T {
    ensureCurrent(generation)
    val candidate = allocateMutationCandidate()
    val policy = artifactPolicy
    var published = false
    try {
      val info = awaitWorkerResult(generation) { completion ->
        prepareMutation(candidate, generation, request, policy::deleteExact, completion)
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
      published = true
      untrackWorkingFile(candidate)
      policy.deleteExact(oldWorking)
      return present()
    } finally {
      if (!published) discardPreparedMutation(candidate, policy::deleteExact)
    }
  }

  fun replaceSession(path: String, generation: Long, fallbackFont: PdfFallbackFont?, completion: (Result<PdfSessionInfo>) -> Unit) {
    sessionWorker.replace(path, generation, fallbackFont, completion)
  }

  fun exportSession(snapshot: PdfExportSnapshot, completion: (Result<String>) -> Unit) {
    sessionWorker.export(snapshot, artifactPolicy, completion)
  }

  fun closeSession(outputs: Collection<java.io.File>, retireOutput: (java.io.File) -> Unit) {
    sessionWorker.close(outputs, retireOutput)
  }

  fun publishOpen(info: PdfSessionInfo): java.io.File? {
    ensureNotDisposed()
    require(info.pages.isNotEmpty())
    val previous = currentWorkingFile()
    mutablePages.clear()
    mutablePages.addAll(info.pages.map { InkPageState(PageRecord.newId(), it) })
    activePageId = mutablePages.first().id
    sourcePath = info.sourcePath
    generationValue = info.generation
    structuralDirty = false
    untrackWorkingFile(java.io.File(info.sourcePath))
    return previous
  }

  fun publishStructuralCandidate(info: PdfSessionInfo, candidate: StructuralCandidate): java.io.File {
    ensureNotDisposed()
    require(info.generation == generation)
    require(info.pageCount == candidate.pages.size)
    val previous = checkNotNull(currentWorkingFile())
    installCandidate(info.sourcePath, candidate.pages, candidate.activePageId)
    untrackWorkingFile(java.io.File(info.sourcePath))
    return previous
  }

  fun clearPublishedDocument() {
    mutablePages.clear()
    activePageId = null
    sourcePath = ""
    structuralDirty = false
  }

  fun dispose() {
    if (disposed) return
    disposed = true
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
