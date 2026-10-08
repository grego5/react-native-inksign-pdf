package com.margelo.nitro.inksignpdf

import android.net.Uri
import java.io.File
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

internal data class TextTargetSlot(
  val id: Long,
  val pageId: String,
  var sourceIdentity: String?,
  var fieldName: String?,
  var canonicalBounds: PageRect,
  var options: TextAnnotationOptions?,
  var embeddedValue: String = "",
  var canonicalWritingRule: CanonicalWritingRule? = null,
  var canonicalDetectionBounds: PageRect = canonicalBounds,
  var excludedSourceRanges: List<IntRange> = emptyList(),
)

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
  private var nextTextId = 1L
  private val textTargets = LinkedHashMap<Long, TextTargetSlot>()
  private val textSourceGlyphs = HashMap<String, List<PdfiumPreparedGlyph>>()
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
    val retainedPageIds = candidatePages.mapTo(HashSet()) { it.id }
    textTargets.entries.removeAll { it.value.pageId !in retainedPageIds }
    textSourceGlyphs.keys.removeAll { it !in retainedPageIds }
    activePageId = candidateActivePageId
    structuralDirty = true
  }

  data class StructuralCandidate(
    val pages: List<InkPageState>,
    val activePageId: String,
  )

  fun appendCandidate(
    dimensions: List<PdfPageDimensions>,
    selection: AddPagesActivePage,
  ): StructuralCandidate {
    require(dimensions.isNotEmpty())
    val appended = dimensions.map { InkPageState(PageRecord.newId(), it) }
    val candidatePages = mutablePages.toList() + appended
    val candidateActivePageId = when (selection) {
      AddPagesActivePage.CURRENT -> activePageId ?: appended.first().id
      AddPagesActivePage.FIRSTADDED -> appended.first().id
      AddPagesActivePage.LASTADDED -> appended.last().id
    }
    return StructuralCandidate(candidatePages, candidateActivePageId)
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

  fun rotatePageCandidate(pageId: String, dimensions: PdfPageDimensions): StructuralCandidate {
    val index = pageIndexForId(pageId)
      ?: throw PdfSessionException("operation_cancelled", "The target page no longer exists")
    val next = mutablePages.toMutableList()
    val current = next[index]
    next[index] = InkPageState(
      current.id,
      dimensions,
      current.history,
      current.geometryRevision + 1L,
      current.sourceDimensions,
    )
    return StructuralCandidate(next, pageId)
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

  fun pageIndexForId(pageId: String): Int? =
    mutablePages.indexOfFirst { it.id == pageId }.takeIf { it >= 0 }

  fun pageForId(pageId: String): InkPageState? = mutablePages.firstOrNull { it.id == pageId }

  fun reserveTextTarget(
    pageId: String,
    sourceIdentity: String?,
    fieldName: String?,
    canonicalBounds: PageRect,
    options: TextAnnotationOptions?,
    embeddedValue: String = "",
    canonicalWritingRule: CanonicalWritingRule? = null,
    canonicalDetectionBounds: PageRect = canonicalBounds,
    excludedSourceRanges: List<IntRange> = emptyList(),
  ): TextTargetSlot {
    if (pageForId(pageId) == null) throw PdfSessionException(
      "operation_cancelled", "The target page no longer exists",
    )
    val existing = findTextTarget(pageId, sourceIdentity, canonicalBounds)
    if (existing != null) return existing
    if (nextTextId > MAX_SAFE_TEXT_ID) throw PdfSessionException(
      "text_id_exhausted", "The view has exhausted its numeric text IDs",
    )
    val slot = TextTargetSlot(nextTextId++, pageId, sourceIdentity, fieldName, canonicalBounds, options,
      embeddedValue, canonicalWritingRule, canonicalDetectionBounds, excludedSourceRanges)
    textTargets[slot.id] = slot
    return slot
  }

  fun textTarget(id: Long): TextTargetSlot = textTargets[id]
    ?: throw PdfSessionException("text_not_found", "The text ID does not belong to this view")

  fun textTargetsForPage(pageId: String): List<TextTargetSlot> =
    textTargets.values.filter { it.pageId == pageId }

  fun findTextTarget(pageId: String, sourceIdentity: String?, canonicalBounds: PageRect): TextTargetSlot? =
    textTargets.values.firstOrNull { slot ->
      slot.pageId == pageId && if (sourceIdentity != null) slot.sourceIdentity == sourceIdentity
      else slot.sourceIdentity == null && sameCanonicalBounds(slot.canonicalBounds, canonicalBounds)
    }

  private fun sameCanonicalBounds(first: PageRect, second: PageRect): Boolean =
    kotlin.math.abs(first.left - second.left) <= 0.000001 &&
      kotlin.math.abs(first.top - second.top) <= 0.000001 &&
      kotlin.math.abs(first.right - second.right) <= 0.000001 &&
      kotlin.math.abs(first.bottom - second.bottom) <= 0.000001

  fun retainTextSourceGlyphs(pageId: String, glyphs: List<PdfiumPreparedGlyph>) {
    // Source text is immutable for the lifetime of a stable page ID.
    if (textSourceGlyphs.containsKey(pageId)) return
    textSourceGlyphs[pageId] = glyphs
    textTargetsForPage(pageId).forEach(::refreshEmbeddedValue)
  }

  fun adoptTextTarget(
    id: Long,
    pageId: String,
    sourceIdentity: String?,
    fieldName: String?,
    canonicalBounds: PageRect,
    embeddedValue: String,
    canonicalWritingRule: CanonicalWritingRule? = null,
    canonicalDetectionBounds: PageRect = canonicalBounds,
    excludedSourceRanges: List<IntRange> = emptyList(),
  ): TextTargetSlot {
    val slot = textTarget(id)
    if (slot.pageId != pageId) throw PdfSessionException(
      "text_not_found", "The text ID belongs to another page",
    )
    if (slot.sourceIdentity != null && sourceIdentity != null && slot.sourceIdentity != sourceIdentity) {
      throw PdfSessionException("text_target_ambiguous", "The annotation belongs to another source field")
    }
    val conflict = findTextTarget(pageId, sourceIdentity, canonicalBounds)
    if (conflict != null && conflict.id != id) throw PdfSessionException(
      "text_target_ambiguous", "The resolved field already has another text target",
    )
    slot.canonicalBounds = canonicalBounds
    if (sourceIdentity != null || slot.sourceIdentity == null) {
      slot.sourceIdentity = sourceIdentity
      slot.fieldName = fieldName
      slot.canonicalWritingRule = canonicalWritingRule
      slot.canonicalDetectionBounds = canonicalDetectionBounds
      slot.excludedSourceRanges = excludedSourceRanges
      slot.embeddedValue = embeddedValue
    }
    return slot
  }

  fun updateTextTargetBounds(id: Long, pageId: String, canonicalBounds: PageRect) {
    val target = textTarget(id)
    if (target.pageId != pageId) throw PdfSessionException(
      "text_not_found", "The text ID belongs to another page",
    )
    target.canonicalBounds = canonicalBounds
    if (target.sourceIdentity == null) {
      target.canonicalDetectionBounds = canonicalBounds
      refreshEmbeddedValue(target)
    }
  }

  private fun refreshEmbeddedValue(target: TextTargetSlot) {
    val glyphs = textSourceGlyphs[target.pageId] ?: return
    target.embeddedValue = embeddedTextInCanonicalRegion(glyphs, target.canonicalDetectionBounds, target.excludedSourceRanges)
  }

  private fun synchronizeTextPlacement(page: InkPageState) {
    page.history.contentSnapshot().mapNotNull { it.textAnnotationOrNull() }.forEach { annotation ->
      updateTextTargetBounds(annotation.id, page.id, annotation.canonicalPlacementBounds)
    }
  }

  fun removeTextTargetsForPage(pageId: String) {
    textTargets.entries.removeAll { it.value.pageId == pageId }
    textSourceGlyphs.remove(pageId)
  }

  fun clearTextTargets() {
    textTargets.clear()
    textSourceGlyphs.clear()
  }

  fun pageHistoryRevision(index: Int): Long = page(index).history.revision
  fun activeHistoryRevision(): Long = activeHistory().revision
  fun activeHistoryState(): InkState = activeHistory().state()
  fun activePageHasInk(): Boolean =
    hasDocument && activeHistory().hasInk()
  fun isDirty(): Boolean = structuralDirty || mutablePages.any { it.history.state().isDirty }

  fun activatePage(index: Int): PageSnapshot {
    setActivePage(index)
    return pageSnapshot(index)
  }

  fun appendActiveInk(outline: StrokeOutline) = activeHistory().append(outline)
  fun appendActiveText(annotation: TextAnnotation) = appendText(page(activePageIndex), annotation)
  fun appendText(page: InkPageState, annotation: TextAnnotation) {
    page.history.appendText(annotation)
    updateTextTargetBounds(annotation.id, page.id, annotation.canonicalPlacementBounds)
  }
  fun replaceActiveText(before: TextAnnotation, after: TextAnnotation) =
    replaceText(page(activePageIndex), before, after)
  fun replaceText(page: InkPageState, before: TextAnnotation, after: TextAnnotation) {
    page.history.replaceText(before, after)
    updateTextTargetBounds(after.id, page.id, after.canonicalPlacementBounds)
  }
  fun removeActiveText(annotation: TextAnnotation) = activeHistory().removeTextAnnotation(annotation)
  fun undoActiveHistory(): InkHistoryMutation = activeHistory().undoMutation().also {
    synchronizeTextPlacement(page(activePageIndex))
  }
  fun redoActiveHistory(): InkHistoryMutation = activeHistory().redoMutation().also {
    synchronizeTextPlacement(page(activePageIndex))
  }
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
    val fallbackFont: AndroidFallbackFont?,
    val workingFile: java.io.File,
    val operationID: Long,
    val previousWorkingFile: java.io.File?,
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

  /** Clears the previous document on admission, then installs only the latest prepared open. */
  suspend fun <P, T> executeOpen(
    sourcePath: String,
    fallbackFont: AndroidFallbackFont?,
    resolveFallbackFont: suspend (AndroidFallbackFont) -> PdfFallbackFont = {
      throw PdfSessionException("invalid_fallback_font", "No Android fallback font resolver is configured")
    },
    awaitContainerSize: suspend () -> ViewportSize,
    invalidatePrevious: () -> Unit = {},
    preparePresentation: (PdfSessionInfo, ViewportSize) -> P,
    beginHandoff: () -> Unit = {},
    publishPresentation: (P) -> T,
    notifyPublished: (T) -> Unit = {},
    abortHandoff: () -> Unit = {},
  ): T {
    val request = beginOpen(fallbackFont, invalidatePrevious)
    var committed = false
    try {
      val preparedOpen: Pair<PdfSessionInfo, PdfFallbackFont?> = awaitUnlessSuperseded(request) {
        withContext(Dispatchers.IO) {
          val source = try {
            val uri = Uri.parse(sourcePath)
            val path = if (uri.scheme.equals("file", ignoreCase = true)) {
              val authority = uri.authority
              if (!authority.isNullOrEmpty() && !authority.equals("localhost", ignoreCase = true)) {
                throw IllegalArgumentException("File URI must refer to the local device")
              }
              uri.path ?: throw IllegalArgumentException("File URI has no path")
            } else {
              sourcePath
            }
            File(path).canonicalFile
          } catch (error: Exception) {
            throw PdfSessionException("invalid_source_path", "Unable to resolve the local PDF path", error)
          }
          if (!source.isFile || !source.canRead()) {
            throw PdfSessionException("invalid_source_path", "Unable to read the PDF")
          }
          source.copyTo(request.workingFile, overwrite = true)
        }
        val resolvedFont: PdfFallbackFont? = if (request.fallbackFont == null) {
          null
        } else {
          resolveFallbackFont(request.fallbackFont)
        }
        val candidate = awaitWorkerResult { completion ->
          sessionWorker.prepareOpen(
            request.attemptId,
            request.workingFile.path,
            resolvedFont,
            completion,
          )
        }
        ensureCurrentOpen(request.attemptId)
        if (candidate.generation != request.attemptId) throw cancelled()
        candidate to resolvedFont
      }
      val info = preparedOpen.first
      val resolvedFallbackFont = preparedOpen.second
      val containerSize = awaitUnlessSuperseded(request, awaitContainerSize)
      ensureCurrentOpen(request.attemptId)
      val presentation = preparePresentation(info, containerSize)
      val preparedCandidate = prepareOpenCandidate(request, info, resolvedFallbackFont)
      synchronized(openStateLock) {
        ensureCurrentOpen(request.attemptId)
        request.handoffFinished = CompletableDeferred()
      }
      beginHandoff()
      currentCoroutineContext().ensureActive()
      ensureCurrentOpen(request.attemptId)

      // A request arriving after this point waits for the handoff to finish.
      val (previousWorkingFile, value) = withContext(NonCancellable) {
        awaitWorkerResult<Unit> { completion ->
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
          awaitWorkerResult<Unit> { completion ->
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
              awaitWorkerResult<Unit> { completion ->
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

  private fun beginOpen(fallbackFont: AndroidFallbackFont?, invalidatePrevious: () -> Unit): OpenRequest {
    val request = synchronized(openStateLock) {
      if (disposed) throw cancelled()
      openRequestSequence += 1L
      val previousOpen = activeOpenRequest
      val previousWorkingFile = currentWorkingFile()
      val workingFile = artifactPolicy.allocateWorkingPdf()
      try {
        val attemptId = sessionWorker.reserveOpenAttemptId(generationValue)
        previousOpen?.superseded?.complete(Unit)
        previousOpen?.handoffFinished?.complete(Unit)
        activeOperation = null
        generationValue = attemptId
        clearPublishedDocument()
        this.fallbackFont = null
        val operationID = nextOperation()
        trackWorkingFile(workingFile)
        previousWorkingFile?.let(::trackWorkingFile)
        sessionWorker.clearCurrentForReplacement { result ->
          result.exceptionOrNull()?.let {
            android.util.Log.e("InkSignPdf", "Unable to close replaced PDF session", it)
          }
          previousWorkingFile?.let(::retireWorkingFile)
        }
        OpenRequest(attemptId, fallbackFont, workingFile, operationID, previousWorkingFile).also {
          activeOpenRequest = it
        }
      } catch (error: Throwable) {
        artifactPolicy.deleteExact(workingFile)
        throw error
      }
    }
    runCatching(invalidatePrevious)
    return request
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

  private fun prepareOpenCandidate(
    request: OpenRequest,
    info: PdfSessionInfo,
    resolvedFallbackFont: PdfFallbackFont?,
  ): PreparedOpenCandidate {
    val pages = info.pages.map { dimensions ->
      InkPageState(PageRecord.newId(), dimensions)
    }.toMutableList()
    return PreparedOpenCandidate(
      pages = pages,
      activePageId = pages.first().id,
      sourcePath = request.workingFile.path,
      generation = request.attemptId,
      fallbackFont = resolvedFallbackFont,
      workingFile = request.workingFile,
      previousWorkingFile = request.previousWorkingFile,
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

  fun trackWorkingFile(file: java.io.File) { synchronized(openStateLock) { workingFiles += file } }
  fun untrackWorkingFile(file: java.io.File) { synchronized(openStateLock) { workingFiles.remove(file) } }
  fun retireWorkingFile(file: java.io.File) {
    untrackWorkingFile(file)
    artifactPolicy.deleteExact(file)
  }
  fun currentWorkingFile(): java.io.File? = sourcePath.takeIf { it.isNotEmpty() }?.let { java.io.File(it) }
  fun workingFiles(): Set<java.io.File> = synchronized(openStateLock) { workingFiles.toSet() }

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

  fun horizontalSnapCandidates(
    generation: Long,
    pageIndex: Int,
    completion: (Result<List<PdfiumHorizontalSnapCandidate>>) -> Unit,
  ) {
    val page = page(pageIndex)
    val transform = PageCoordinates(page.dimensions).layoutToDisplay(page.sourceDimensions)
    sessionWorker.horizontalSnapCandidates(generation, pageIndex) { result ->
      completion(result.map { transformRules(it, transform) })
    }
  }

  fun preparePageAnalysis(
    generation: Long,
    pageIndex: Int,
    completion: (Result<PdfiumPreparedPageAnalysis>) -> Unit,
  ) {
    if (generation != generationValue || pageIndex !in mutablePages.indices) {
      completion(Result.failure(PdfSessionException(
        "operation_cancelled", "The target page is no longer available",
      )))
      return
    }
    sessionWorker.preparePageAnalysis(generation, pageIndex, completion)
  }

  private fun transformRules(
    rules: List<PdfiumHorizontalSnapCandidate>,
    transform: PageTransform,
  ): List<PdfiumHorizontalSnapCandidate> = rules.mapNotNull { rule ->
    val start = transform.map(PagePoint(rule.left, rule.y))
    val end = transform.map(PagePoint(rule.right, rule.y))
    if (kotlin.math.abs(start.y - end.y) > 0.001) null else {
      val verticalScale = kotlin.math.abs(
        transform.map(PagePoint(rule.left, rule.y + 1.0)).y - transform.map(PagePoint(rule.left, rule.y)).y,
      )
      PdfiumHorizontalSnapCandidate(minOf(start.x, end.x), maxOf(start.x, end.x), start.y,
        rule.labelLineHeight?.times(verticalScale))
    }
  }

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
      val info = awaitWorkerResult { completion ->
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
      awaitWorkerResult<Unit> { completion ->
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
    clearTextTargets()
    markStructuralClean()
  }

  fun closeDocument() {
    activeOpenRequest?.superseded?.complete(Unit)
    activeOpenRequest?.handoffFinished?.complete(Unit)
    activeOpenRequest = null
    activeOperation = null
    sessionWorker.cancel(generationValue)
    generationValue += 1L
    val files = workingFiles() + listOfNotNull(currentWorkingFile())
    clearPublishedDocument()
    sessionWorker.clearCurrentForReplacement {
      files.forEach(::retireWorkingFile)
    }
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
      info.pages.indices.any { index -> info.pages[index] != candidate.pages[index].sourceDimensions }
    ) {
      throw PdfSessionException(
        "pdf_mutation_failed",
        "The assembled PDF page metadata does not match the structural candidate",
      )
    }
  }

  private suspend fun <T> awaitWorkerResult(
    start: (((Result<T>) -> Unit) -> Unit),
  ): T = suspendCancellableCoroutine { continuation ->
    start { result ->
      result.fold(
        onSuccess = { value -> continuation.resume(value) },
        onFailure = { error -> continuation.resumeWithException(error) },
      )
    }
  }

  private fun cancelled(): PdfSessionException = PdfSessionException(
    "operation_cancelled",
    "PDF view was disposed or the open was superseded",
  )
}

private const val MAX_SAFE_TEXT_ID = 9_007_199_254_740_991L
