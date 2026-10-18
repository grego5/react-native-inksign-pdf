package com.margelo.nitro.inksignpdf

import android.graphics.Color

/** Immutable final cubic contour collection owned by history and reused by export/rendering. */
internal class StrokeOutline private constructor(
  val contourPathData: List<InkPathData>,
) {
  val color: Int get() = contourPathData.first().color
  fun withColor(color: Int): StrokeOutline = StrokeOutline(contourPathData.map { it.copy(color = color) })
  val cubicSegmentCount: Int
    get() = contourPathData.sumOf { data ->
      data.commands.count { it.type == InkPathCommand.CUBIC }
    }

  companion object {
    fun copyOf(source: StrokeContour): StrokeOutline {
      val data = CubicStrokePathBuilder.buildData(source)
      return StrokeOutline(listOf(data))
    }

    fun copyOf(sources: List<StrokeContour>): StrokeOutline {
      require(sources.isNotEmpty()) { "Native contour collection must not be empty" }
      val contourData = sources.map(CubicStrokePathBuilder::buildData)
      return StrokeOutline(contourData)
    }

    internal fun fromCommands(commands: List<InkPathCommand>): StrokeOutline =
      StrokeOutline(listOf(InkPathData.fromCommands(commands)))
  }
}

/** Immutable text layout in the captured page orientation, with a top-left origin. */
internal data class TextAnnotation(
  val id: Long,
  val text: String,
  val bounds: PageRect,
  val fontSize: Double,
  /** Opaque ARGB text color captured when the annotation was created. */
  val textColor: Int = Color.BLACK,
  /** Fixed paragraph base direction selected before this annotation was created. */
  val directionRtl: Boolean = false,
  /** Optional page-point flow and clip region for programmatic or option-based placement. */
  val flowBounds: PageRect? = null,
  /** Maximum number of complete visible lines; zero retains every line that fits. */
  val maxLines: Int = 0,
  /** Vertical edge fixed by programmatic or option-based placement. */
  val verticalAnchor: TextVerticalAnchor = TextVerticalAnchor.TOP,
  /** Logical paragraph alignment within the fixed flow region. */
  val alignment: TextAlignment = TextAlignment.START,
  /** Page orientation in which layout coordinates were captured; null means raw content space. */
  val layoutPage: PdfPageDimensions? = null,
  val font: NamedFontResource? = null,
  val autoWidth: Boolean = false,
  val autoHeight: Boolean = false,
) {
  val layoutToCanonical: PageTransform
    get() = layoutPage?.let { PageCoordinates(it).displayToRawTransform() }
      ?: PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

  val placementBounds: PageRect
    get() {
      val flow = flowBounds ?: bounds
      return PageRect(
        if (autoWidth) bounds.left else flow.left, if (autoHeight) bounds.top else flow.top,
        if (autoWidth) bounds.right else flow.right, if (autoHeight) bounds.bottom else flow.bottom)
    }

  val canonicalPlacementBounds: PageRect
    get() = textAnnotationOuterBounds(placementBounds, layoutToCanonical, 0.0, 0.0)

  fun layoutToDisplay(page: PdfPageDimensions): PageTransform =
    layoutToCanonical.then(PageCoordinates(page).canonicalToDisplayTransform())

  init {
    require(id > 0L) { "Text annotation ID must be positive" }
    require(text.isNotBlank()) { "Committed text annotation must not be blank" }
    require(fontSize.isFinite() && fontSize > 0.0) {
      "Text annotation font size must be finite and positive"
    }
    require(maxLines >= 0) { "Text annotation line limit must be non-negative" }
    require(
      bounds.left.isFinite() && bounds.top.isFinite() &&
        bounds.right.isFinite() && bounds.bottom.isFinite() &&
        bounds.right >= bounds.left && bounds.bottom >= bounds.top,
    ) { "Text annotation bounds must be finite and non-inverted" }
  }

  /** Top-left layout position; presentation zoom is not stored. */
  val position: PagePoint
    get() = PagePoint(bounds.left, bounds.top)

  /** Intrinsic longest-line width and multiline height in canonical page units. */
  val intrinsicWidth: Double
    get() = bounds.right - bounds.left

  val intrinsicHeight: Double
    get() = bounds.bottom - bounds.top
}

/** One ordered, committed page-content entry. */
internal sealed interface PageContent {
  data class Ink(val outline: StrokeOutline) : PageContent
  data class Text(val annotation: TextAnnotation) : PageContent
}

internal fun PageContent.inkOutlineOrNull(): StrokeOutline? = when (this) {
  is PageContent.Ink -> outline
  is PageContent.Text -> null
}

internal fun PageContent.textAnnotationOrNull(): TextAnnotation? = when (this) {
  is PageContent.Ink -> null
  is PageContent.Text -> annotation
}

private fun List<PageContent>.inkOutlines(): List<StrokeOutline> =
  mapNotNull { it.inkOutlineOrNull() }

internal data class InkState(
  val canUndo: Boolean,
  val canRedo: Boolean,
  val isDirty: Boolean,
)

internal sealed interface InkHistoryMutation {
  data class Appended(val outline: StrokeOutline) : InkHistoryMutation
  data class Removed(val outline: StrokeOutline) : InkHistoryMutation
  data class Replaced(val content: List<PageContent>) : InkHistoryMutation
  data class Cleared(val content: List<PageContent>) : InkHistoryMutation
  data object NoOp : InkHistoryMutation
}

/** UI-thread-owned permanent base and ordered, undoable overrides. */
internal class PageContentHistory(private val recordHistory: Boolean = true) {
  val textState = PageTextState()
  private var editingId: Long? = null
  private var editingChanged = false

  fun applyTextState(id: Long, annotation: TextAnnotation?, changed: Boolean) {
    textState.apply(id, annotation)
    editingId = id
    editingChanged = changed
    revision += 1L
  }

  fun finishTextState(id: Long) {
    check(editingId == null || editingId == id)
    editingId = null
    editingChanged = false
    applyHistoryState()
  }

  private sealed interface Key {
    data class Ink(val outline: StrokeOutline) : Key
    data class Text(val id: Long) : Key
  }
  /** A null content entry hides a base item until the tracked deletion is undone. */
  private data class Entry(val key: Key, val content: PageContent?)
  private sealed class HistoryAction {
    class Edit(val index: Int, val before: Entry?, val after: Entry?) : HistoryAction()
    class Clear(val before: List<Entry>, val after: List<Entry>) : HistoryAction()
  }

  private val base = ArrayList<Entry>()
  private val tracked = ArrayList<Entry>()
  /** Text targets keep their identity after deletion or undo, until document retirement. */
  private val insertedInputTargetIds = HashSet<Long>()
  private val undoStack = ArrayList<HistoryAction>()
  private val redoStack = ArrayList<HistoryAction>()
  var revision: Long = 0L
    private set

  private fun PageContent.key(): Key = when (this) {
    is PageContent.Ink -> Key.Ink(outline)
    is PageContent.Text -> Key.Text(annotation.id)
  }

  val canUndo: Boolean get() = undoStack.isNotEmpty()
  val canRedo: Boolean get() = redoStack.isNotEmpty()

  fun state() = InkState(canUndo, canRedo, isDirty = canUndo || (recordHistory && editingChanged))

  /** Base first, then tracked content; overrides suppress the matching base identity. */
  private fun historyContent(): List<PageContent> {
    val overridden = tracked.mapTo(HashSet()) { it.key }
    return base.filterNot { it.key in overridden }.mapNotNull { it.content } + tracked.mapNotNull { it.content }
  }

  private fun applyHistoryState() {
    val id = editingId
    val draft = id?.let { textState.target(it).annotation }
    val states = historyContent().filterIsInstance<PageContent.Text>().map { it.annotation }
    textState.apply(if (id == null) states else states.filterNot { it.id == id } + listOfNotNull(draft))
  }

  fun contentSnapshot(): List<PageContent> {
    val content = historyContent().mapNotNull { item ->
      if (item is PageContent.Text) textState.target(item.annotation.id).annotation?.let { PageContent.Text(it) } else item
    }
    val id = editingId ?: return content
    return content.filterNot { it is PageContent.Text && it.annotation.id == id } +
      listOfNotNull(textState.target(id).annotation?.let { PageContent.Text(it) })
  }
  fun snapshot(): List<StrokeOutline> = contentSnapshot().inkOutlines()
  fun hasInk(): Boolean = contentSnapshot().any { it is PageContent.Ink }
  fun hasText(): Boolean = contentSnapshot().any { it is PageContent.Text }

  private fun HistoryAction.affects(key: Key): Boolean = when (this) {
    is HistoryAction.Edit -> before?.key == key || after?.key == key
    is HistoryAction.Clear -> before.any { it.key == key } || after.any { it.key == key }
  }

  /** Includes retained redo entries, so an untracked call cannot bypass a tracked branch. */
  private fun isTracked(key: Key): Boolean = tracked.any { it.key == key } ||
    undoStack.any { it.affects(key) } || redoStack.any { it.affects(key) }

  private fun applyEntry(index: Int, before: Entry?, after: Entry?) {
    if (before == null) {
      tracked.add(index, checkNotNull(after))
    } else {
      check(tracked[index] == before) { "History entry does not match the current tracked content" }
      if (after == null) tracked.removeAt(index) else tracked[index] = after
    }
  }

  private fun edit(key: Key, after: PageContent?, untracked: Boolean) {
    if (!recordHistory || (untracked && !isTracked(key))) {
      val index = base.indexOfFirst { it.key == key }
      if (after == null) {
        check(index >= 0) { "Base removal target is missing" }
        base.removeAt(index)
      } else if (index < 0) base += Entry(key, after) else base[index] = Entry(key, after)
      applyHistoryState()
      revision += 1L
      return
    }

    val existingIndex = tracked.indexOfFirst { it.key == key }
    val index = if (existingIndex < 0) tracked.size else existingIndex
    val before = tracked.getOrNull(existingIndex)
    val entry = if (after != null || base.any { it.key == key }) Entry(key, after) else null
    check(before != entry) { "A tracked edit must change its override" }
    applyEntry(index, before, entry)
    undoStack += HistoryAction.Edit(index, before, entry)
    redoStack.clear()
    applyHistoryState()
    revision += 1L
  }

  /** Newly allocated content has no override or retained history to look up. */
  private fun appendFresh(content: PageContent, untracked: Boolean = false) {
    val entry = Entry(content.key(), content)
    if (!recordHistory || untracked) {
      base += entry
    } else {
      val index = tracked.size
      tracked += entry
      undoStack += HistoryAction.Edit(index, null, entry)
      redoStack.clear()
    }
    applyHistoryState()
    revision += 1L
  }

  fun append(outline: StrokeOutline) = appendFresh(PageContent.Ink(outline))
  fun append(content: PageContent) = when (content) {
    is PageContent.Ink -> append(content.outline)
    is PageContent.Text -> appendText(content.annotation)
  }
  fun appendText(annotation: TextAnnotation, untracked: Boolean = false) {
    if (insertedInputTargetIds.add(annotation.id)) {
      appendFresh(PageContent.Text(annotation), untracked)
      return
    }
    check(contentSnapshot().none { it.key() == Key.Text(annotation.id) }) { "Text identity already exists" }
    edit(Key.Text(annotation.id), PageContent.Text(annotation), untracked)
  }
  fun replace(before: PageContent, after: PageContent) {
    require(before != after && before.key() == after.key()) { "Replacement must retain content identity" }
    check(before in contentSnapshot()) { "Replacement target is missing" }
    edit(before.key(), after, untracked = false)
  }
  fun replaceText(before: TextAnnotation, after: TextAnnotation, untracked: Boolean = false) {
    require(before != after && before.id == after.id) { "Replacement must retain text identity" }
    check(PageContent.Text(before) in contentSnapshot()) { "Text replacement target is missing" }
    edit(Key.Text(before.id), PageContent.Text(after), untracked)
  }
  fun remove(content: PageContent) {
    check(content in contentSnapshot()) { "Removal target is missing" }
    edit(content.key(), null, untracked = false)
  }
  fun removeTextAnnotation(annotation: TextAnnotation, untracked: Boolean = false) {
    check(PageContent.Text(annotation) in contentSnapshot()) { "Text removal target is missing" }
    edit(Key.Text(annotation.id), null, untracked)
  }

  private fun HistoryAction.Edit.mutation(undo: Boolean): InkHistoryMutation {
    val removed = if (undo) after else before
    val added = if (undo) before else after
    return when {
      removed == null && added?.content is PageContent.Ink ->
        InkHistoryMutation.Appended(added.content.outline)
      added == null && removed?.content is PageContent.Ink ->
        InkHistoryMutation.Removed(removed.content.outline)
      else -> InkHistoryMutation.Replaced(contentSnapshot())
    }
  }

  fun undoMutation(): InkHistoryMutation {
    val action = undoStack.removeLastOrNull() ?: return InkHistoryMutation.NoOp
    when (action) {
      is HistoryAction.Edit -> applyEntry(action.index, action.after, action.before)
      is HistoryAction.Clear -> {
        check(tracked == action.after) { "Undo tracked state does not match history" }
        tracked.clear()
        tracked.addAll(action.before)
      }
    }
    redoStack += action
    applyHistoryState()
    revision += 1L
    return if (action is HistoryAction.Edit) action.mutation(undo = true)
      else InkHistoryMutation.Replaced(contentSnapshot())
  }

  fun redoMutation(): InkHistoryMutation {
    val action = redoStack.removeLastOrNull() ?: return InkHistoryMutation.NoOp
    when (action) {
      is HistoryAction.Edit -> applyEntry(action.index, action.before, action.after)
      is HistoryAction.Clear -> {
        check(tracked == action.before) { "Redo tracked state does not match history" }
        tracked.clear()
        tracked.addAll(action.after)
      }
    }
    undoStack += action
    applyHistoryState()
    revision += 1L
    return if (action is HistoryAction.Edit) action.mutation(undo = false)
      else InkHistoryMutation.Replaced(contentSnapshot())
  }

  private fun clearMatching(predicate: (PageContent) -> Boolean): InkHistoryMutation {
    val beforeContent = contentSnapshot()
    if (beforeContent.none(predicate)) return InkHistoryMutation.NoOp
    if (!recordHistory) {
      base.removeAll { it.content?.let(predicate) == true }
    } else {
      val after = tracked.mapNotNull { entry ->
        if (entry.content?.let(predicate) != true) entry
        else if (base.any { it.key == entry.key }) Entry(entry.key, null) else null
      }.toMutableList()
      base.filter { it.content?.let(predicate) == true }.forEach { entry ->
        if (after.none { it.key == entry.key }) after += Entry(entry.key, null)
      }
      undoStack += HistoryAction.Clear(tracked.toList(), after.toList())
      tracked.clear()
      tracked.addAll(after)
      redoStack.clear()
    }
    applyHistoryState()
    revision += 1L
    return InkHistoryMutation.Replaced(contentSnapshot())
  }
  fun clearMutation(): InkHistoryMutation {
    val before = contentSnapshot()
    val mutation = clearMatching { true }
    return if (mutation == InkHistoryMutation.NoOp) mutation else InkHistoryMutation.Cleared(before)
  }
  fun clearInkMutation(): InkHistoryMutation = clearMatching { it is PageContent.Ink }

  fun revertChanges() {
    check(editingId == null) { "Finish text editing before reverting history" }
    tracked.clear()
    undoStack.clear()
    redoStack.clear()
    applyHistoryState()
    revision += 1L
  }

  fun acceptChanges() {
    check(editingId == null) { "Finish text editing before resetting history" }
    val current = contentSnapshot()
    base.clear()
    base.addAll(current.map { Entry(it.key(), it) })
    tracked.clear()
    undoStack.clear()
    redoStack.clear()
    applyHistoryState()
    revision += 1L
  }

  fun reset() {
    base.clear()
    tracked.clear()
    insertedInputTargetIds.clear()
    undoStack.clear()
    redoStack.clear()
    applyHistoryState()
    revision += 1L
  }
}
