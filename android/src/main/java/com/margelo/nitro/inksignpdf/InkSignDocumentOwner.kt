package com.margelo.nitro.inksignpdf

import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference
import java.util.concurrent.CountDownLatch

/** Only the viewer implements presentation; document commands never require a surface. */
internal interface DocumentTextPresentation {
  fun draftText(id: Long): String?
  fun draftFontSize(id: Long): Double?
  fun setDraft(id: Long, text: String, options: TextAnnotationOptions?): Boolean
  fun setDraftOptions(id: Long, options: TextAnnotationOptions): Boolean
  fun cancelDraft(id: Long)
  fun resolveDirection(direction: TextDirection?): Boolean
  fun requireModeSession(token: ModeSessionToken)
  fun focusPreparedText(context: TextPageContext, id: Double, options: TextFocusOptions?): com.margelo.nitro.core.Promise<Unit>
  fun contentChanged(generation: Long, pageId: String, before: TextAnnotation?, after: TextAnnotation?)
}

/** Central owner of document state and programmatic text edits, with optional presentation. */
internal class InkSignDocumentOwner(
  val coordinator: MutableDocumentCoordinator,
  val fonts: NamedFontRegistry,
  val recordHistory: Boolean,
  private val appDirectionIsRtl: () -> Boolean,
) {
  var presentation: WeakReference<DocumentTextPresentation>? = null
  var closed = false
    private set
  private var acceptingCommands = true
  var defaultFontSize = 16.0
  var defaultTextColor = android.graphics.Color.BLACK
  val commandMutex = kotlinx.coroutines.sync.Mutex()
  private val prepared = LinkedHashMap<Pair<String, ModeSessionToken?>, PreparedPageContext>()

  fun retainPrepared(context: PreparedPageContext): PreparedPageContext {
    prepared.entries.removeAll { it.value.generation != coordinator.generation || coordinator.pageForId(it.value.pageId) == null }
    return prepared.getOrPut(context.pageId to context.modeSession) { context }
  }
  fun clearPrepared() { prepared.clear() }
  fun releasePrepared(session: ModeSessionToken) {
    prepared.keys.removeAll { it.second === session }
  }

  /** Shared import transaction; the viewer supplies only readiness/presentation hooks. */
  suspend fun <T> appendPages(
    input: PageInputCoordinator,
    options: AddPagesOptions?,
    imageDimensions: PdfPageDimensions,
    resolveFallback: suspend () -> PdfFallbackFont?,
    beforeMutation: () -> Unit = {},
    validate: (PdfSessionInfo, MutableDocumentCoordinator.StructuralCandidate) -> Unit = { _, _ -> },
    present: (Int) -> T,
  ): T {
    val operation = coordinator.beginOperation(requireDocument = false)
    var staged = emptyList<StagedPageInput>()
    try {
      val generation = coordinator.generation
      staged = input.stage(options)
      coordinator.ensureCurrent(generation)
      if (staged.isEmpty()) return present(0)
      val fallback = resolveFallback()
      coordinator.ensureCurrent(generation)
      beforeMutation()
      val requests = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        staged.map { source ->
          when (source.type) {
            PageType.PDF -> PdfiumAppendRequest(PageType.PDF, sourcePath = source.file.path)
            PageType.IMAGE -> ImagePageEncoder.encode(source.file, imageDimensions, options?.targetDpi, options?.jpegQuality)
          }
        }
      }
      coordinator.ensureCurrent(generation)
      val count = coordinator.pageCount
      return coordinator.executeStructuralMutation(
        generation, PdfiumAssemblyRequest(if (count == 0) PdfiumAssemblyOperation.CREATE else PdfiumAssemblyOperation.APPEND,
          appendInputs = requests),
        candidateBuilder = { info ->
          val added = info.pages.drop(count)
          if (added.isEmpty()) throw PdfSessionException("pdf_mutation_failed", "The append candidate contains no added pages")
          coordinator.appendCandidate(added, options?.activePage ?: AddPagesActivePage.CURRENT)
        },
        validate = validate,
        present = { present(coordinator.pageCount - count) },
        fontFallback = fallback,
      )
    } finally { input.release(staged); coordinator.endOperation(operation) }
  }

  fun stopAdmissions() { acceptingCommands = false }
  fun invalidate() { closed = true; acceptingCommands = false; presentation = null; clearPrepared() }
  private fun resolveDirection(direction: TextDirection?): Boolean =
    presentation?.get()?.resolveDirection(direction) ?: when (direction) {
      TextDirection.RTL -> true
      TextDirection.LTR -> false
      else -> appDirectionIsRtl()
    }

  private fun commit(page: InkPageState, before: TextAnnotation?, after: TextAnnotation?) {
    when {
      before == null -> coordinator.appendText(page, checkNotNull(after))
      after == null -> page.history.removeTextAnnotation(before)
      before != after -> coordinator.replaceText(page, before, after)
    }
    if (!recordHistory) page.history.discardUndo()
    presentation?.get()?.contentChanged(coordinator.generation, page.id, before, after)
  }

  private fun merged(previous: TextAnnotationOptions?, options: TextAnnotationOptions?) = TextAnnotationOptions(
    options?.font ?: previous?.font, options?.fontSize ?: previous?.fontSize,
    options?.color ?: previous?.color, options?.direction ?: previous?.direction,
    options?.maxLines ?: previous?.maxLines, options?.alignment ?: previous?.alignment,
    options?.verticalAnchor ?: previous?.verticalAnchor,
  )

  /** Snapshot current formatting only when removing content leaves an empty target. */
  private fun emptyTargetOptions(annotation: TextAnnotation) = TextAnnotationOptions(
    fonts.selection(annotation.font), annotation.fontSize,
    String.format(java.util.Locale.ROOT, "#%06X", annotation.textColor and 0xffffff),
    if (annotation.directionRtl) TextDirection.RTL else TextDirection.LTR,
    annotation.maxLines.toDouble(), annotation.alignment, annotation.verticalAnchor,
  )

  internal fun readPreparedTextValue(context: TextPageContext, rawId: Double): String = withTextPage(context) { page ->
    val slot = requireTextTarget(context, rawId)
    presentation?.get()?.draftText(slot.id) ?: moduleAnnotations(page.id).firstOrNull { it.id == slot.id }?.text ?: slot.embeddedValue
  }

  private fun annotation(page: InkPageState, slot: TextTargetSlot, current: TextAnnotation?, text: String,
                         options: TextAnnotationOptions): TextAnnotation {
    val font = fonts.resolve(options.font, current?.font)
    val flow = if (current == null) displayedTargetBounds(slot, page) else current.flowBounds
    requireHorizontalRule(slot, page)
    val candidate = TextAnnotation(
      id = slot.id, text = text, bounds = current?.bounds ?: checkNotNull(flow),
      fontSize = options.fontSize ?: current?.fontSize ?: defaultFontSize,
      textColor = parseTextColor(options.color, current?.textColor ?: defaultTextColor),
      directionRtl = options.direction?.let(::resolveDirection) ?: current?.directionRtl ?: resolveDirection(null),
      flowBounds = flow,
      maxLines = options.maxLines?.toInt() ?: current?.maxLines ?: 0,
      alignment = options.alignment ?: current?.alignment ?: TextAlignment.START,
      verticalAnchor = options.verticalAnchor ?: current?.verticalAnchor ?: TextVerticalAnchor.TOP,
      layoutPage = current?.layoutPage ?: page.dimensions, font = font,
    )
    if (flow != null) return candidate.copy(bounds = TextLayoutSpec.visibleBounds(candidate, flow))
    val measured = TextLayoutSpec.measure(text, candidate.fontSize, font?.typeface ?: TextLayoutSpec.typeface)
    val size = measured.copy(width = maxOf(measured.width, textEditorMinimumContentWidth(candidate.fontSize)))
    val position = clampTextAnnotationPosition(candidate.position, size, candidate.layoutPage ?: page.dimensions)
    return candidate.copy(bounds = PageRect(position.x, position.y, position.x + size.width, position.y + size.height))
  }

  internal fun setPreparedTextValue(context: TextPageContext, rawId: Double, text: String,
                                    options: TextAnnotationOptions? = null) = withTextPage(context) { page ->
    val slot = requireTextTarget(context, rawId)
    if (text.isNotEmpty() && presentation?.get()?.setDraft(slot.id, text, options) == true) {
      return@withTextPage
    }
    val current = moduleAnnotations(page.id).firstOrNull { it.id == slot.id }
    val proposed = merged(if (current == null) slot.options else null, options)
    // Resolve font and compute layout before publishing any target, draft, or content changes.
    fonts.resolve(proposed.font, current?.font)
    val updated = if (text.isEmpty()) null else annotation(page, slot, current, text, proposed)
    if (text.isEmpty()) presentation?.get()?.cancelDraft(slot.id)
    slot.options = if (text.isEmpty() && current != null) merged(emptyTargetOptions(current), options)
      else merged(slot.options, options)
    if (current != updated) commit(page, current, updated)
  }

  internal fun setPreparedTextOptions(context: TextPageContext, rawId: Double,
                                      options: TextAnnotationOptions) = withTextPage(context) { page ->
    val slot = requireTextTarget(context, rawId)
    if (presentation?.get()?.setDraftOptions(slot.id, options) == true) return@withTextPage
    val current = moduleAnnotations(page.id).firstOrNull { it.id == slot.id }
    val proposed = merged(if (current == null) slot.options else null, options)
    fonts.resolve(proposed.font, current?.font)
    val updated = current?.let { annotation(page, slot, it, it.text, proposed) }
    slot.options = merged(slot.options, options)
    if (current != updated) commit(page, current, updated)
  }

  internal fun adjustPreparedTextSize(context: TextPageContext, rawId: Double, delta: Double): Double = withTextPage(context) { page ->
    val slot = requireTextTarget(context, rawId)
    val size = presentation?.get()?.draftFontSize(slot.id)
      ?: moduleAnnotations(page.id).firstOrNull { it.id == slot.id }?.fontSize ?: slot.options?.fontSize ?: defaultFontSize
    val adjusted = (size + delta).coerceIn(minimumTextFontSize, maximumTextFontSize)
    if (adjusted != size) setPreparedTextOptions(context, rawId,
      TextAnnotationOptions(null, adjusted, null, null, null, null, null))
    adjusted
  }

  internal fun resolvePreparedText(context: PreparedPageContext, options: ResolveTextOptions): Double =
    withTextPage(context) { page ->
      fonts.resolve(options.font)
      coordinator.retainTextSourceGlyphs(page.id, context.analysis.glyphs)
      val coordinates = PageCoordinates(page.dimensions)
      val transform = coordinates.canonicalToDisplayTransform()
      val selected = if (options.fieldName == null) {
        val bounds = options.bounds ?: throw PdfSessionException(
          "invalid_text_bounds", "Free text resolution requires bounds",
        )
        val rect = programmaticTextFlowBounds(bounds, page.dimensions)
        val canonicalBounds = coordinates.displayToCanonical(rect)
        val reserved = coordinator.findTextTarget(page.id, null, canonicalBounds)
        val existing = moduleAnnotations(page.id).filter {
          displayedAnnotationBounds(it, page).intersectsTarget(rect)
        }.also { if (it.size > 1) throw PdfSessionException("text_target_ambiguous", "Multiple annotations occupy the target") }.singleOrNull()
        val embedded = embeddedTextInCanonicalRegion(context.analysis.glyphs, canonicalBounds)
        if (reserved != null) reserved else if (existing != null) coordinator.adoptTextTarget(
          existing.id, page.id, null, null, canonicalBounds, embedded,
        ) else coordinator.reserveTextTarget(
          page.id, null, null, canonicalBounds, options.toAnnotationOptions(), embedded,
        )
      } else {
        val directionRtl = resolveDirection(options.direction)
        val candidates = completeLabelMatches(context.labels, options.fieldName)
          .filter { label ->
            val matchBounds = projectMatchBounds(label.match, transform)
            options.bounds?.let { region ->
              val left = region.x
              val top = region.y
              val right = left + region.width
              val bottom = top + region.height
              matchBounds.left >= left && matchBounds.top >= top &&
                matchBounds.right <= right && matchBounds.bottom <= bottom
            } ?: true
          }
        if (candidates.isEmpty()) throw PdfSessionException(
          "text_key_not_found", "The complete field label was not found on the captured page",
        )
        val projectedRules = context.analysis.rules.mapNotNull { rule ->
          val start = transform.map(rule.start)
          val end = transform.map(rule.end)
          if (kotlin.math.abs(start.y - end.y) > 0.001) null else
            rule to PdfiumHorizontalSnapCandidate(minOf(start.x, end.x), maxOf(start.x, end.x), start.y)
        }
        val projectedMatches = candidates.map { projectMatch(label = it, transform = transform) }
        val placement = selectPdfiumTextKeyPlacement(
          projectedMatches, projectedRules.map { it.second },
          options.occurrence ?: TextKeyOccurrence.FIRST, directionRtl, page.dimensions,
        ) ?: throw PdfSessionException(
          "text_rule_not_found", "The complete field label has no usable adjacent rule",
        )
        val label = candidates.firstOrNull {
          projectMatch(it, transform).sourceIndex == placement.match.sourceIndex
        } ?: throw IllegalStateException("Resolved prepared label is missing")
        val anchor = options.verticalAnchor ?: TextVerticalAnchor.BOTTOM
        if (placement.rule.y <= 0.0 || placement.rule.y >= page.dimensions.height) {
          throw PdfSessionException("text_rule_not_found", "The selected rule leaves no target area")
        }
        val fieldBounds = if (anchor == TextVerticalAnchor.BOTTOM) {
          PageRect(placement.contentLeft, 0.0, placement.contentRight, placement.rule.y)
        } else {
          PageRect(placement.contentLeft, placement.rule.y, placement.contentRight, page.dimensions.height)
        }
        val band = valueBand(placement, anchor)
        val matchingAnnotation = moduleAnnotations(page.id).filter { displayedAnnotationBounds(it, page).intersectsTarget(band) }
        if (matchingAnnotation.size > 1) throw PdfSessionException("text_target_ambiguous", "Multiple annotations occupy the field")
        val canonicalRule = projectedRules.first { it.second == placement.rule }.first
        val identity = "${label.identity}|${canonicalRule.sourceIndex}"
        val canonicalBounds = coordinates.displayToCanonical(fieldBounds)
        val canonicalBand = coordinates.displayToCanonical(band)
        val embeddedValue = embeddedTextInCanonicalRegion(context.analysis.glyphs, canonicalBand, label.sourceRanges)
        coordinator.findTextTarget(page.id, identity, canonicalBounds)?.let { target ->
          coordinator.adoptTextTarget(
            target.id, page.id, identity, options.fieldName, canonicalBounds,
            embeddedValue, canonicalRule, canonicalBand, label.sourceRanges,
          )
        } ?: matchingAnnotation.singleOrNull()?.let { annotation ->
          coordinator.adoptTextTarget(
            annotation.id, page.id, identity, options.fieldName, canonicalBounds,
            embeddedValue, canonicalRule, canonicalBand, label.sourceRanges,
          )
        } ?: coordinator.reserveTextTarget(
          page.id, identity, options.fieldName, canonicalBounds, options.toAnnotationOptions(), embeddedValue,
          canonicalRule, canonicalBand, label.sourceRanges,
        )
      }
      selected.id.toDouble()
    }

  internal fun preparedTextEntry(context: TextPageContext, rawId: Double): TextEntry =
    withTextPage(context) { page ->
      val slot = requireTextTarget(context, rawId)
      val annotation = moduleAnnotations(page.id).firstOrNull { it.id == slot.id }
      val draft = presentation?.get()?.draftText(slot.id)
      val value = draft ?: annotation?.text ?: slot.embeddedValue
      val source = when {
        draft != null || annotation != null -> TextValueSource.ANNOTATION
        slot.embeddedValue.isNotEmpty() -> TextValueSource.EMBEDDED
        else -> TextValueSource.EMPTY
      }
      TextEntry(slot.id.toDouble(), value, slot.fieldName, displayedTargetBounds(slot, page).toPublicBounds(), source)
    }

  internal fun preparedTextEntries(context: TextPageContext): Array<TextEntry> =
    withTextPage(context) { page ->
      coordinator.textTargetsForPage(page.id).map { slot ->
        val annotation = moduleAnnotations(page.id).firstOrNull { it.id == slot.id }
        val draft = presentation?.get()?.draftText(slot.id)
        val value = draft ?: annotation?.text ?: slot.embeddedValue
        val source = when {
          draft != null || annotation != null -> TextValueSource.ANNOTATION
          slot.embeddedValue.isNotEmpty() -> TextValueSource.EMBEDDED
          else -> TextValueSource.EMPTY
        }
        TextEntry(slot.id.toDouble(), value, slot.fieldName, displayedTargetBounds(slot, page).toPublicBounds(), source)
      }.toTypedArray()
    }

  /** Admission for synchronous reads and edits; queued async work drains independently. */
  internal fun <T> withDocument(action: () -> T): T =
    runOnMainSync {
      checkMainThread()
      if (!acceptingCommands || closed || !coordinator.hasDocument) throw operationCancelled()
      action()
    }

  internal fun <T> withTextPage(context: TextPageContext, action: (InkPageState) -> T): T =
    withDocument {
      context.modeSession?.let { checkNotNull(presentation?.get()).requireModeSession(it) }
      if (coordinator.generation != context.generation) throw operationCancelled()
      val page = coordinator.pageForId(context.pageId) ?: throw operationCancelled()
      action(page)
    }

  internal fun requireTextTarget(context: TextPageContext, rawId: Double): TextTargetSlot {
    if (!rawId.isFinite() || rawId <= 0.0 || rawId % 1.0 != 0.0 ||
      rawId > 9_007_199_254_740_991.0) {
      throw PdfSessionException("invalid_text_id", "Text IDs must be positive safe integers")
    }
    val slot = coordinator.textTarget(rawId.toLong())
    if (slot.pageId != context.pageId) throw PdfSessionException(
      "text_not_found", "The text ID belongs to another page",
    )
    return slot
  }

  private fun moduleAnnotations(pageId: String): List<TextAnnotation> =
    coordinator.pageForId(pageId)?.history?.contentSnapshot()?.mapNotNull { it.textAnnotationOrNull() }.orEmpty()

  private fun projectMatchBounds(match: PdfiumTextKeyMatch, transform: PageTransform): PageRect =
    textAnnotationOuterBounds(PageRect(match.left, match.top, match.right, match.bottom), transform, 0.0, 0.0)

  private fun projectMatch(label: PreparedTextLabel, transform: PageTransform): PdfiumTextKeyMatch {
    val bounds = projectMatchBounds(label.match, transform)
    val rowStart = transform.map(label.match.rowStart).let { PagePoint(it.x, it.y) }
    val rowEnd = transform.map(label.match.rowEnd).let { PagePoint(it.x, it.y) }
    return label.match.copy(left = bounds.left, top = bounds.top, right = bounds.right,
      bottom = bounds.bottom, lineCenter = (rowStart.y + rowEnd.y) / 2.0,
      lineHeight = kotlin.math.abs(rowEnd.y - rowStart.y), rowStart = rowStart, rowEnd = rowEnd)
  }

  private fun PageRect.intersectsTarget(other: PageRect) = left < other.right && right > other.left && top < other.bottom && bottom > other.top

  private fun displayedAnnotationBounds(annotation: TextAnnotation, page: InkPageState): PageRect =
    textAnnotationOuterBounds(annotation.bounds, annotation.layoutToDisplay(page.dimensions), 0.0, 0.0)

  internal fun displayedTargetBounds(slot: TextTargetSlot, page: InkPageState): PageRect {
    val transform = PageCoordinates(page.dimensions).canonicalToDisplayTransform()
    slot.canonicalWritingRule?.let { rule ->
      val start = transform.map(rule.start)
      val end = transform.map(rule.end)
      if (kotlin.math.abs(start.y - end.y) <= 0.001) {
        val bottom = (slot.options?.verticalAnchor ?: TextVerticalAnchor.BOTTOM) == TextVerticalAnchor.BOTTOM
        val flow = textAnnotationOuterBounds(slot.canonicalBounds, transform, 0.0, 0.0)
        return PageRect(flow.left, if (bottom) 0.0 else start.y,
          flow.right, if (bottom) start.y else page.dimensions.height)
      }
    }
    return textAnnotationOuterBounds(slot.canonicalBounds, transform, 0.0, 0.0)
  }

  internal fun requireHorizontalRule(slot: TextTargetSlot, page: InkPageState): PdfiumHorizontalSnapCandidate? {
    val rule = slot.canonicalWritingRule ?: return null
    val transform = PageCoordinates(page.dimensions).canonicalToDisplayTransform()
    val start = transform.map(rule.start)
    val end = transform.map(rule.end)
    if (kotlin.math.abs(start.y - end.y) > 0.001) throw PdfSessionException("text_rule_not_found", "The writing rule is vertical")
    return PdfiumHorizontalSnapCandidate(minOf(start.x, end.x), maxOf(start.x, end.x), start.y)
  }

  private fun valueBand(placement: PdfiumTextKeyPlacement, anchor: TextVerticalAnchor): PageRect =
    PageRect(placement.rule.left,
      if (anchor == TextVerticalAnchor.BOTTOM) placement.rule.y - placement.match.lineHeight else placement.rule.y,
      placement.rule.right,
      if (anchor == TextVerticalAnchor.BOTTOM) placement.rule.y else placement.rule.y + placement.match.lineHeight)



  private fun checkMainThread() { check(Looper.myLooper() == Looper.getMainLooper()) }
  private fun operationCancelled() = PdfSessionException("operation_cancelled", "The document or page is no longer available")
  internal fun <T> runOnMainSync(action: () -> T): T {
    if (Looper.myLooper() == Looper.getMainLooper()) return action()
    val latch = CountDownLatch(1)
    var outcome: Result<T>? = null
    Handler(Looper.getMainLooper()).post { try { outcome = runCatching(action) } finally { latch.countDown() } }
    latch.await()
    return checkNotNull(outcome).getOrThrow()
  }
}
