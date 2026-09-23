package com.margelo.nitro.inksignpdf

import android.graphics.Color

/** Immutable final cubic contour collection owned by history and reused by export/rendering. */
internal class StrokeOutline private constructor(
  val contourPathData: List<InkPathData>,
) {
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

/** Immutable committed text annotation in canonical top-left page coordinates. */
internal data class TextAnnotation(
  val id: String,
  val text: String,
  val bounds: PageRect,
  val fontSize: Double,
  /** Opaque ARGB text color captured when the annotation was created. */
  val textColor: Int = Color.BLACK,
  /** Fixed paragraph base direction selected before this annotation was created. */
  val directionRtl: Boolean = false,
) {
  init {
    require(id.isNotBlank()) { "Text annotation ID must not be blank" }
    require(text.isNotBlank()) { "Committed text annotation must not be blank" }
    require(fontSize.isFinite() && fontSize > 0.0) {
      "Text annotation font size must be finite and positive"
    }
    require(
      bounds.left.isFinite() && bounds.top.isFinite() &&
        bounds.right.isFinite() && bounds.bottom.isFinite() &&
        bounds.right >= bounds.left && bounds.bottom >= bounds.top,
    ) { "Text annotation bounds must be finite and non-inverted" }
  }

  /** Canonical top-left position; zoom and view transforms are not stored. */
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

/** UI-thread-owned ordered page content and undo/redo state. */
internal class InkHistory {
  private sealed interface HistoryAction {
    class Added(val index: Int, val content: PageContent) : HistoryAction
    class Removed(val index: Int, val content: PageContent) : HistoryAction
    class Replaced(
      val index: Int,
      val before: PageContent,
      val after: PageContent,
    ) : HistoryAction
    class Clear(val content: List<PageContent>) : HistoryAction
  }

  private val completed = ArrayList<PageContent>()
  private val undoStack = ArrayList<HistoryAction>()
  private val redoStack = ArrayList<HistoryAction>()
  var revision: Long = 0L
    private set

  fun state() = InkState(undoStack.isNotEmpty(), redoStack.isNotEmpty(), completed.isNotEmpty())
  /** Ink-only projection retained for the existing ink renderer and exporter. */
  fun snapshot(): List<StrokeOutline> = completed.inkOutlines()

  /** Immutable ordered page-content snapshot for text-aware consumers. */
  fun contentSnapshot(): List<PageContent> = completed.toList()

  fun append(outline: StrokeOutline) {
    append(PageContent.Ink(outline))
  }

  fun append(content: PageContent) {
    val index = completed.size
    completed += content
    undoStack += HistoryAction.Added(index, content)
    redoStack.clear()
    revision += 1L
  }

  fun appendText(annotation: TextAnnotation) {
    append(PageContent.Text(annotation))
  }

  fun replace(before: PageContent, after: PageContent) {
    require(before != after) { "Page content replacement must change the entry" }
    val index = completed.indexOfFirst { it === before || it == before }
    check(index >= 0) { "Page content replacement target is not in history" }
    completed[index] = after
    undoStack += HistoryAction.Replaced(index, before, after)
    redoStack.clear()
    revision += 1L
  }

  fun replaceText(before: TextAnnotation, after: TextAnnotation) {
    replace(PageContent.Text(before), PageContent.Text(after))
  }

  fun remove(content: PageContent) {
    val index = completed.indexOfFirst { it === content || it == content }
    check(index >= 0) { "Page content removal target is not in history" }
    completed.removeAt(index)
    undoStack += HistoryAction.Removed(index, content)
    redoStack.clear()
    revision += 1L
  }

  fun removeTextAnnotation(annotation: TextAnnotation) {
    remove(PageContent.Text(annotation))
  }

  fun undoMutation(): InkHistoryMutation {
    val action = undoStack.removeLastOrNull() ?: return InkHistoryMutation.NoOp
    return when (action) {
      is HistoryAction.Added -> {
        check(completed.removeAt(action.index) === action.content)
        redoStack += action
        revision += 1L
        mutationForContentChange(action.content, added = false)
      }
      is HistoryAction.Removed -> {
        completed.add(action.index, action.content)
        redoStack += action
        revision += 1L
        mutationForContentChange(action.content, added = true)
      }
      is HistoryAction.Replaced -> {
        check(completed[action.index] === action.after || completed[action.index] == action.after)
        completed[action.index] = action.before
        redoStack += action
        revision += 1L
        InkHistoryMutation.Replaced(contentSnapshot())
      }
      is HistoryAction.Clear -> {
        check(completed.isEmpty())
        completed.addAll(action.content)
        redoStack += action
        revision += 1L
        InkHistoryMutation.Replaced(contentSnapshot())
      }
    }
  }

  fun redoMutation(): InkHistoryMutation {
    val action = redoStack.removeLastOrNull() ?: return InkHistoryMutation.NoOp
    return when (action) {
      is HistoryAction.Added -> {
        check(action.index == completed.size)
        completed.add(action.index, action.content)
        undoStack += action
        revision += 1L
        mutationForContentChange(action.content, added = true)
      }
      is HistoryAction.Removed -> {
        check(completed[action.index] === action.content || completed[action.index] == action.content)
        completed.removeAt(action.index)
        undoStack += action
        revision += 1L
        mutationForContentChange(action.content, added = false)
      }
      is HistoryAction.Replaced -> {
        check(completed[action.index] === action.before || completed[action.index] == action.before)
        completed[action.index] = action.after
        undoStack += action
        revision += 1L
        InkHistoryMutation.Replaced(contentSnapshot())
      }
      is HistoryAction.Clear -> {
        completed.clear()
        undoStack += action
        revision += 1L
        InkHistoryMutation.Cleared(action.content)
      }
    }
  }

  fun clearMutation(): InkHistoryMutation {
    if (completed.isEmpty()) return InkHistoryMutation.NoOp
    val content = contentSnapshot()
    undoStack += HistoryAction.Clear(content)
    completed.clear()
    redoStack.clear()
    revision += 1L
    return InkHistoryMutation.Cleared(content)
  }

  fun reset() {
    completed.clear(); undoStack.clear(); redoStack.clear(); revision += 1L
  }

  private fun mutationForContentChange(
    content: PageContent,
    added: Boolean,
  ): InkHistoryMutation {
    return when (content) {
      is PageContent.Ink -> if (added) {
        InkHistoryMutation.Appended(content.outline)
      } else {
        InkHistoryMutation.Removed(content.outline)
      }
      is PageContent.Text -> InkHistoryMutation.Replaced(contentSnapshot())
    }
  }
}
