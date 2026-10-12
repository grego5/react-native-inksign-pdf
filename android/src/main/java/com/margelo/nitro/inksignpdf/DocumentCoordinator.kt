package com.margelo.nitro.inksignpdf

import com.margelo.nitro.core.NullType
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
  private val recordHistory: Boolean = true,
) : DocumentReadState {
  private var mutablePages: MutableList<InkPageState> = pages.map { dimensions ->
    InkPageState(PageRecord.newId(), dimensions, history = InkHistory(recordHistory))
  }.toMutableList()
  private var generationValue = generation
  private var activeOpenRequest: OpenRequest? = null
  private val openStateLock = Any()
  // Tracks arrival order, including requests queued behind a handoff.
  // Worker attempt IDs are reserved only after a request is admitted.
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
    } else {
      require(sourcePath.isEmpty())
    }
  }

  override var sourcePath: String = sourcePath
    private set

  override val generation: Long
    get() = generationValue

  /** Immutable view of the published page records. Page histories remain owned by this coordinator. */
  val pages: List<InkPageState>
    get() = mutablePages.toList()

  override val hasDocument: Boolean
    get() = mutablePages.isNotEmpty()

  override val pageCount: Int
    get() = mutablePages.size

  fun page(index: Int): InkPageState {
    require(index in mutablePages.indices)
    return mutablePages[index]
  }

  override fun pageMetadata(index: Int): DocumentPageMetadata = page(index).metadata()

  private val ownerIdentity = java.util.UUID.randomUUID().toString()

  override fun documentInfo(): DocumentState = DocumentState(
    if (hasDocument) Variant_NullType_String.create("$ownerIdentity:$generation")
      else Variant_NullType_String.create(NullType.NULL),
    pageCount.toDouble(), isDirty(),
  )

  override fun pageInfo(index: Int): PageInfo {
    val event = pageChangeEvent(index)
    val history = page(index).history
    return PageInfo(pageId = event.pageId, pageIndex = index.toDouble(), pageCount = pageCount.toDouble(),
      width = event.width, height = event.height, rotation = event.rotation,
      hasInk = history.hasInk(), hasText = history.hasText(), isDirty = history.state().isDirty,
      canUndo = event.canUndo, canRedo = event.canRedo)
  }

  override fun pageChangeEvent(index: Int): PageChangeEvent {
    val page = page(index)
    val history = page.history
    return PageChangeEvent(pageId = page.id,
      width = page.dimensions.width, height = page.dimensions.height,
      rotation = (page.dimensions.rotation * 90).toDouble(),
      canUndo = history.canUndo, canRedo = history.canRedo)
  }

  fun installCandidate(
    candidatePath: String,
    candidatePages: List<InkPageState>,
  ) {
    require(candidatePath.isNotEmpty())
    require(candidatePages.isNotEmpty())
    sourcePath = candidatePath
    mutablePages.clear()
    mutablePages.addAll(candidatePages)
    val retainedPageIds = candidatePages.mapTo(HashSet()) { it.id }
    textTargets.entries.removeAll { it.value.pageId !in retainedPageIds }
    textSourceGlyphs.keys.removeAll { it !in retainedPageIds }
    structuralDirty = true
  }

  data class StructuralCandidate(
    val pages: List<InkPageState>,
  )

  fun appendCandidate(
    dimensions: List<PdfPageDimensions>,
  ): StructuralCandidate {
    require(dimensions.isNotEmpty())
    val appended = dimensions.map { InkPageState(PageRecord.newId(), it, history = InkHistory(recordHistory)) }
    val candidatePages = mutablePages.toList() + appended
    return StructuralCandidate(candidatePages)
  }

  fun removePageCandidate(source: Int): StructuralCandidate {
    check(pageCount > 1) { "The document must retain one page" }
    val next = mutablePages.toMutableList().also { it.removeAt(source) }
    return StructuralCandidate(next)
  }

  fun movePageCandidate(source: Int, destination: Int): StructuralCandidate {
    check(destination in mutablePages.indices) { "Admitted move destination is outside the document" }
    if (source == destination) return StructuralCandidate(mutablePages.toList())
    val next = mutablePages.toMutableList().also {
      val moved = it.removeAt(source)
      it.add(destination, moved)
    }
    return StructuralCandidate(next)
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
    return StructuralCandidate(next)
  }

  fun markStructuralDirty() { structuralDirty = true }

  fun markStructuralClean() { structuralDirty = false }

  fun pageRecords(): List<PageRecord> = pages.map { page -> PageRecord(page.id, page.dimensions) }

  override fun sessionInfo(): PdfSessionInfo = PdfSessionInfo(
    sourcePath = sourcePath,
    pages = pages.map { it.dimensions },
    generation = generation,
  )

  data class Snapshot(
    val sourcePath: String,
    val generation: Long,
    val pages: List<PageSnapshot>,
    val structuralDirty: Boolean,
  )

  data class PageSnapshot(
    val id: String,
    val dimensions: PdfPageDimensions,
    val content: List<PageContent>,
  )

  override fun pageSnapshot(index: Int): PageSnapshot {
    val page = page(index)
    return PageSnapshot(page.id, page.dimensions, page.history.contentSnapshot())
  }

  override fun pageIndexForId(pageId: String): Int? =
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
  ): TextTargetSlot = findTextTarget(pageId, sourceIdentity, canonicalBounds) ?:
    prepareTextTarget(pageId, sourceIdentity, fieldName, canonicalBounds, options,
      embeddedValue, canonicalWritingRule, canonicalDetectionBounds, excludedSourceRanges).also(::publishTextTarget)

  /** Allocates identity without publishing a target until candidate construction succeeds. */
  fun prepareTextTarget(
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
    if (nextTextId > MAX_SAFE_TEXT_ID) throw PdfSessionException(
      "text_id_exhausted", "The view has exhausted its numeric text IDs",
    )
    val slot = TextTargetSlot(nextTextId++, pageId, sourceIdentity, fieldName, canonicalBounds, options,
      embeddedValue, canonicalWritingRule, canonicalDetectionBounds, excludedSourceRanges)
    return slot
  }

  fun publishTextTarget(slot: TextTargetSlot) {
    textTargets[slot.id] = slot
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

  override fun pageHistoryRevision(index: Int): Long = page(index).history.revision
  override fun pageHistoryState(index: Int): InkState = page(index).history.state()
  override fun isDirty(): Boolean = structuralDirty || mutablePages.any { it.history.state().isDirty }
  fun appendText(page: InkPageState, annotation: TextAnnotation, untracked: Boolean = false) {
    page.history.appendText(annotation, untracked)
    updateTextTargetBounds(annotation.id, page.id, annotation.canonicalPlacementBounds)
  }
  fun replaceText(page: InkPageState, before: TextAnnotation, after: TextAnnotation, untracked: Boolean = false) {
    page.history.replaceText(before, after, untracked)
    updateTextTargetBounds(after.id, page.id, after.canonicalPlacementBounds)
  }
  fun undoHistory(page: InkPageState): InkHistoryMutation = page.history.undoMutation().also {
    synchronizeTextPlacement(page)
  }
  fun redoHistory(page: InkPageState): InkHistoryMutation = page.history.redoMutation().also {
    synchronizeTextPlacement(page)
  }
  fun clearHistory(page: InkPageState): InkHistoryMutation = page.history.clearMutation()
  fun clearInk(page: InkPageState): InkHistoryMutation = page.history.clearInkMutation()

  override fun completedPagesSnapshot(): List<PdfPageContentSnapshot> =
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
      structuralDirty = structuralDirty,
    )
  }

  override fun presentationSnapshot(): Snapshot = snapshot()

  internal data class OpenRequest(
    val attemptId: Long,
    val fallbackFont: AndroidFallbackFont?,
    val workingFile: java.io.File,
    val operationID: Long,
    val previousWorkingFile: java.io.File?,
    val superseded: CompletableDeferred<Unit> = CompletableDeferred(),
  )

  internal data class PreparedOpenCandidate(
    val pages: MutableList<InkPageState>,
    val sourcePath: String,
    val generation: Long,
    val fallbackFont: PdfFallbackFont?,
    val workingFile: java.io.File,
    val previousWorkingFile: java.io.File?,
  )

  internal class PendingOpen(
    internal val request: OpenRequest,
    internal val candidate: PreparedOpenCandidate,
    val info: PdfSessionInfo,
  ) {
    internal var published = false
    internal var ended = false
  }

  /** Retires the old document and prepares a detached reader/model without publishing it. */
  suspend fun prepareOpen(
    fallbackFont: AndroidFallbackFont?,
    resolveFallbackFont: suspend (AndroidFallbackFont) -> PdfFallbackFont,
    prepareSource: suspend (java.io.File) -> Unit,
    invalidatePrevious: () -> Unit = {},
  ): PendingOpen {
    val request = beginOpen(fallbackFont)
    try {
      invalidatePrevious()
      val (info, font) = awaitUnlessSuperseded(request) {
        prepareSource(request.workingFile)
        val font = request.fallbackFont?.let { resolveFallbackFont(it) }
        val info = awaitWorkerResult { sessionWorker.prepareOpen(request.attemptId, request.workingFile.path, font, it) }
        ensureCurrentOpen(request.attemptId)
        check(info.generation == request.attemptId)
        info to font
      }
      return PendingOpen(request, prepareOpenCandidate(request, info, font), info)
    } catch (error: Throwable) {
      try { discardDetachedOpen(request) } finally { endOperation(request.operationID) }
      throw error
    }
  }

  /** Keeps presentation readiness cancellable when a newer open supersedes this candidate. */
  internal suspend fun <T> awaitOpen(pending: PendingOpen, action: suspend () -> T): T {
    check(!pending.ended && !pending.published)
    ensureCurrentOpen(pending.request.attemptId)
    return awaitUnlessSuperseded(pending.request, action).also {
      ensureCurrentOpen(pending.request.attemptId)
    }
  }

  /** A matching reader and model publish together even when the caller is cancelled. */
  suspend fun commitOpen(pending: PendingOpen, notifyPublished: (PdfSessionInfo) -> Unit = {}): PdfSessionInfo {
    check(!pending.ended && !pending.published)
    val request = pending.request
    ensureCurrentOpen(request.attemptId)
    currentCoroutineContext().ensureActive()
    return withContext(NonCancellable) {
      awaitWorkerResult<Unit> { sessionWorker.commitPreparedOpen(request.attemptId, it) }
      if (disposed) throw cancelled()
      synchronized(openStateLock) {
        ensureCurrentOpen(request.attemptId)
        publishOpenCandidate(pending.candidate)
        pending.published = true
      }
      try { notifyPublished(pending.info) }
      finally {
        awaitWorkerResult<Unit> { sessionWorker.retireReplacedOpenSession(request.attemptId, it) }
        pending.candidate.previousWorkingFile?.let(::retireWorkingFile)
      }
      pending.info
    }
  }

  suspend fun finishOpen(pending: PendingOpen) {
    check(!pending.ended)
    pending.ended = true
    try { if (!pending.published) discardDetachedOpen(pending.request) }
    finally { endOperation(pending.request.operationID) }
  }

  private suspend fun discardDetachedOpen(request: OpenRequest) = withContext(NonCancellable) {
    try { awaitWorkerResult<Unit> { sessionWorker.discardPreparedOpen(request.attemptId, it) } }
    finally { retireWorkingFile(request.workingFile) }
  }

  private fun beginOpen(fallbackFont: AndroidFallbackFont?): OpenRequest {
    val request = synchronized(openStateLock) {
      if (disposed) throw cancelled()
      val previousOpen = activeOpenRequest
      val previousWorkingFile = currentWorkingFile()
      val workingFile = artifactPolicy.allocateWorkingPdf()
      try {
        val attemptId = sessionWorker.reserveOpenAttemptId(generationValue)
        previousOpen?.superseded?.complete(Unit)
        activeOperation = null
        generationValue = attemptId
        clearPublishedDocument()
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
      InkPageState(PageRecord.newId(), dimensions, history = InkHistory(recordHistory))
    }.toMutableList()
    return PreparedOpenCandidate(
      pages = pages,
      sourcePath = request.workingFile.path,
      generation = request.attemptId,
      fallbackFont = resolvedFallbackFont,
      workingFile = request.workingFile,
      previousWorkingFile = request.previousWorkingFile,
    )
  }

  private fun publishOpenCandidate(candidate: PreparedOpenCandidate) {
    mutablePages = candidate.pages
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

  suspend fun executeStructuralMutation(
    generation: Long,
    request: PdfiumAssemblyRequest,
    candidateBuilder: (PdfSessionInfo) -> StructuralCandidate,
    notifyPublished: () -> Unit = {},
    fontFallback: PdfFallbackFont? = fallbackFont,
  ) {
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
      withContext(NonCancellable) {
        awaitWorkerResult<Unit> { completion -> commitPreparedMutation(candidate, generation, completion) }
        ensureCurrent(generation)
        val oldWorking = publishStructuralCandidate(info, pageCandidate)
        fallbackFont = fontFallback
        published = true
        untrackWorkingFile(candidate)
        try { notifyPublished() } finally { oldWorking?.let(policy::deleteExact) }
      }
    } finally {
      if (!published) discardPreparedMutation(candidate, policy::deleteExact)
    }
  }

  fun exportSession(snapshot: PdfExportSnapshot, completion: (Result<String>) -> Unit) {
    sessionWorker.export(snapshot, artifactPolicy, completion)
  }

  fun publishStructuralCandidate(info: PdfSessionInfo, candidate: StructuralCandidate): java.io.File? {
    ensureNotDisposed()
    require(info.generation == generation)
    require(info.pageCount == candidate.pages.size)
    val previous = currentWorkingFile()
    installCandidate(info.sourcePath, candidate.pages)
    untrackWorkingFile(java.io.File(info.sourcePath))
    return previous
  }

  fun clearPublishedDocument() {
    mutablePages.clear()
    sourcePath = ""
    fallbackFont = null
    clearTextTargets()
    markStructuralClean()
  }

  fun closeDocument(completion: (Result<Unit>) -> Unit = {}) {
    activeOpenRequest?.superseded?.complete(Unit)
    activeOpenRequest = null
    activeOperation = null
    sessionWorker.cancel(generationValue)
    generationValue += 1L
    val files = workingFiles() + listOfNotNull(currentWorkingFile())
    clearPublishedDocument()
    sessionWorker.clearCurrentForReplacement { result ->
      completion(result.map { files.forEach(::retireWorkingFile) })
    }
  }

  fun dispose() {
    if (disposed) return
    disposed = true
    activeOpenRequest?.superseded?.complete(Unit)
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
