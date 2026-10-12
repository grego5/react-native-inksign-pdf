package com.margelo.nitro.inksignpdf

internal data class TextTargetFocus(val bounds: PageRect, val rule: PdfiumHorizontalSnapCandidate?)

/** Committed text and target operations; drafts and mode sessions belong to clients. */
internal class DocumentTextCommands(
  private val core: DocumentCore,
  private val appDirectionIsRtl: () -> Boolean,
) {
  private val coordinator get() = core.coordinator
  private val fonts get() = core.fonts
  var defaultFontSize = defaultTextFontSize
  var defaultTextColor = android.graphics.Color.BLACK

  internal fun resolveDirection(direction: TextDirection?): Boolean = when (direction) {
    TextDirection.RTL -> true
    TextDirection.LTR -> false
    else -> appDirectionIsRtl()
  }

  private fun commit(page: InkPageState, before: TextAnnotation?, after: TextAnnotation?, untracked: Boolean = false) {
    if (before == after) return
    when {
      before == null -> coordinator.appendText(page, checkNotNull(after), untracked)
      after == null -> page.history.removeTextAnnotation(before, untracked)
      else -> coordinator.replaceText(page, before, after, untracked)
    }
    core.changed(DocumentChange.Text(page.id))
  }

  internal fun applyEdit(context: TextPageContext, before: TextAnnotation?, after: TextAnnotation?) =
    core.withMutablePage(context) { page ->
      val id = checkNotNull(after?.id ?: before?.id)
      target(context, id.toDouble())
      check(before == null || before.id == id) { "An edit cannot change text identity" }
      val current = moduleAnnotations(page.id).firstOrNull { it.id == id }
      if (current != before) throw PdfSessionException(
        "operation_cancelled", "The committed text changed during editing",
      )
      commit(page, before, after)
    }

  internal fun reserve(context: TextPageContext, canonicalBounds: PageRect,
                       options: TextAnnotationOptions? = null): Long = core.withMutablePage(context) { page ->
    fonts.resolve(options?.font)
    coordinator.reserveTextTarget(page.id, null, null, canonicalBounds, options).id
  }

  internal fun targetId(context: TextPageContext, rawId: Double): Long = core.withMutablePage(context) {
    target(context, rawId).id
  }

  internal fun focusTarget(context: TextPageContext, rawId: Double): TextTargetFocus = core.withMutablePage(context) { page ->
    val slot = target(context, rawId)
    TextTargetFocus(displayedTargetBounds(slot, page), requireHorizontalRule(slot, page))
  }

  internal fun buildAnnotation(
    id: Long, text: String, bounds: PageRect, page: PdfPageDimensions,
    fontSize: Double, textColor: Int, directionRtl: Boolean,
    flowBounds: PageRect? = null, maxLines: Int = 0,
    verticalAnchor: TextVerticalAnchor = TextVerticalAnchor.TOP,
    alignment: TextAlignment = TextAlignment.START,
    layoutPage: PdfPageDimensions? = page, font: NamedFontResource? = null,
    intrinsicSize: TextIntrinsicSize? = null,
  ): TextAnnotation = TextAnnotationLayout.reflow(TextAnnotation(
    id = id, text = text, bounds = bounds, fontSize = fontSize, textColor = textColor,
    directionRtl = directionRtl, flowBounds = flowBounds, maxLines = maxLines,
    verticalAnchor = verticalAnchor, alignment = alignment, layoutPage = layoutPage, font = font,
  ), page, intrinsicSize)

  internal fun insert(context: TextPageContext, bounds: TextAnnotationBounds, text: String,
                      options: TextAnnotationOptions? = null, requireVisibleLine: Boolean = false,
                      directionRtl: Boolean = resolveDirection(options?.direction)): TextAnnotation = core.withMutablePage(context) { page ->
    val flow = programmaticTextFlowBounds(bounds, page.dimensions)
    val font = fonts.resolve(options?.font)
    val slot = coordinator.prepareTextTarget(page.id, null, null,
      PageCoordinates(page.dimensions).displayToCanonical(flow), options)
    val annotation = buildAnnotation(slot.id, text, flow, page.dimensions,
      options?.fontSize ?: defaultFontSize, parseTextColor(options?.color, defaultTextColor), directionRtl,
      flowBounds = flow, maxLines = options?.maxLines?.toInt() ?: 0,
      verticalAnchor = options?.verticalAnchor ?: TextVerticalAnchor.TOP,
      alignment = options?.alignment ?: TextAlignment.START, font = font)
    if (requireVisibleLine && (annotation.bounds.right <= annotation.bounds.left ||
      annotation.bounds.bottom <= annotation.bounds.top)) {
      throw PdfSessionException("text_rule_not_found", "No complete text line fits beside the selected rule")
    }
    coordinator.publishTextTarget(slot)
    commit(page, null, annotation, untracked = options?.untracked == true)
    annotation
  }

  private fun merged(previous: TextAnnotationOptions?, options: TextAnnotationOptions?) = TextAnnotationOptions(
    null,
    options?.font ?: previous?.font, options?.fontSize ?: previous?.fontSize,
    options?.color ?: previous?.color, options?.direction ?: previous?.direction,
    options?.maxLines ?: previous?.maxLines, options?.alignment ?: previous?.alignment,
    options?.verticalAnchor ?: previous?.verticalAnchor,
  )

  /** Snapshot current formatting only when removing content leaves an empty target. */
  private fun emptyTargetOptions(annotation: TextAnnotation) = TextAnnotationOptions(
    null,
    fonts.selection(annotation.font), annotation.fontSize,
    String.format(java.util.Locale.ROOT, "#%06X", annotation.textColor and 0xffffff),
    if (annotation.directionRtl) TextDirection.RTL else TextDirection.LTR,
    annotation.maxLines.toDouble(), annotation.alignment, annotation.verticalAnchor,
  )

  internal fun getValue(context: TextPageContext, rawId: Double): String = core.withMutablePage(context) { page ->
    val slot = target(context, rawId)
    moduleAnnotations(page.id).firstOrNull { it.id == slot.id }?.text ?: slot.embeddedValue
  }

  private fun annotation(page: InkPageState, slot: TextTargetSlot, current: TextAnnotation?, text: String,
                         options: TextAnnotationOptions): TextAnnotation {
    val font = fonts.resolve(options.font, current?.font)
    val flow = if (current == null) displayedTargetBounds(slot, page) else current.flowBounds
    if (current == null) requireHorizontalRule(slot, page)
    val layoutPage = if (current == null) page.dimensions else current.layoutPage
    return buildAnnotation(
      id = slot.id, text = text, bounds = current?.bounds ?: checkNotNull(flow),
      fontSize = options.fontSize ?: current?.fontSize ?: defaultFontSize,
      textColor = parseTextColor(options.color, current?.textColor ?: defaultTextColor),
      directionRtl = options.direction?.let(::resolveDirection) ?: current?.directionRtl ?: resolveDirection(null),
      flowBounds = flow,
      maxLines = options.maxLines?.toInt() ?: current?.maxLines ?: 0,
      alignment = options.alignment ?: current?.alignment ?: TextAlignment.START,
      verticalAnchor = options.verticalAnchor ?: current?.verticalAnchor ?: TextVerticalAnchor.TOP,
      layoutPage = layoutPage, font = font,
      page = layoutPage ?: PageCoordinates(page.dimensions).rawPage,
    )
  }

  internal fun setValue(context: TextPageContext, rawId: Double, text: String,
                        options: TextAnnotationOptions? = null) = core.withMutablePage(context) { page ->
    val slot = target(context, rawId)
    val current = moduleAnnotations(page.id).firstOrNull { it.id == slot.id }
    val proposed = merged(if (current == null) slot.options else null, options)
    // Resolve font and compute layout before publishing target or content changes.
    fonts.resolve(proposed.font, current?.font)
    val updated = if (text.isEmpty()) null else annotation(page, slot, current, text, proposed)
    slot.options = if (text.isEmpty() && current != null) merged(emptyTargetOptions(current), options)
      else merged(slot.options, options)
    commit(page, current, updated, untracked = options?.untracked == true)
  }

  internal fun setOptions(context: TextPageContext, rawId: Double,
                          options: TextAnnotationOptions) = core.withMutablePage(context) { page ->
    val slot = target(context, rawId)
    val current = moduleAnnotations(page.id).firstOrNull { it.id == slot.id }
    val proposed = merged(if (current == null) slot.options else null, options)
    fonts.resolve(proposed.font, current?.font)
    val updated = current?.let { annotation(page, slot, it, it.text, proposed) }
    slot.options = merged(slot.options, options)
    commit(page, current, updated, untracked = options.untracked == true)
  }

  internal fun adjustSize(context: TextPageContext, rawId: Double, delta: Double): Double = core.withMutablePage(context) { page ->
    val slot = target(context, rawId)
    val size = moduleAnnotations(page.id).firstOrNull { it.id == slot.id }?.fontSize ?: slot.options?.fontSize ?: defaultFontSize
    val adjusted = (size + delta).coerceIn(minimumTextFontSize, maximumTextFontSize)
    if (adjusted != size) setOptions(context, rawId,
      TextAnnotationOptions(null, null, adjusted, null, null, null, null, null))
    adjusted
  }

  internal fun resolve(context: PreparedPageContext, options: ResolveTextOptions): Double =
    core.withMutablePage(context) { page ->
      fonts.resolve(options.font)
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

  internal fun getEntry(context: TextPageContext, rawId: Double): TextEntry =
    core.withMutablePage(context) { page ->
      val slot = target(context, rawId)
      val annotation = moduleAnnotations(page.id).firstOrNull { it.id == slot.id }
      val value = annotation?.text ?: slot.embeddedValue
      val source = when {
        annotation != null -> TextValueSource.ANNOTATION
        slot.embeddedValue.isNotEmpty() -> TextValueSource.EMBEDDED
        else -> TextValueSource.EMPTY
      }
      TextEntry(slot.id.toDouble(), value, slot.fieldName, displayedTargetBounds(slot, page).toPublicBounds(), source)
    }

  internal fun getEntries(context: TextPageContext): Array<TextEntry> =
    core.withMutablePage(context) { page ->
      val annotations = moduleAnnotations(page.id).associateBy { it.id }
      coordinator.textTargetsForPage(page.id).map { slot ->
        val annotation = annotations[slot.id]
        val value = annotation?.text ?: slot.embeddedValue
        val source = when {
          annotation != null -> TextValueSource.ANNOTATION
          slot.embeddedValue.isNotEmpty() -> TextValueSource.EMBEDDED
          else -> TextValueSource.EMPTY
        }
        TextEntry(slot.id.toDouble(), value, slot.fieldName, displayedTargetBounds(slot, page).toPublicBounds(), source)
      }.toTypedArray()
    }

  private fun target(context: TextPageContext, rawId: Double): TextTargetSlot {
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

  private fun displayedTargetBounds(slot: TextTargetSlot, page: InkPageState): PageRect {
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

  private fun requireHorizontalRule(slot: TextTargetSlot, page: InkPageState): PdfiumHorizontalSnapCandidate? {
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
}
