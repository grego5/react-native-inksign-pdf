package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InkHistoryTest {
  @Test
  fun documentPagesKeepHistoryAndDirtyStateIndependent() {
    val document = InkDocumentState(
      sourcePath = "multi-page.pdf",
      generation = 1L,
      pages = listOf(
        PdfPageDimensions(300.0, 400.0),
        PdfPageDimensions(600.0, 800.0),
      ),
    )
    val first = outline(0f)
    val second = outline(20f)
    document.page(0).history.append(first)
    document.page(1).history.append(second)

    assertEquals(listOf(first), document.page(0).history.snapshot())
    assertEquals(listOf(second), document.page(1).history.snapshot())
    assertTrue(document.pages.any { it.history.state().isDirty })

    document.page(0).history.clearMutation()
    assertTrue(document.page(1).history.state().isDirty)
  }

  @Test
  fun strokeUndoRedoAndClearKeepStateSnapshotsConsistent() {
    val history = InkHistory()
    val first = outline(0f)
    val second = outline(20f)
    assertEquals(InkState(false, false, false), history.state())
    history.append(first); assertEquals(InkState(true, false, true), history.state())
    history.append(second); history.undoMutation()
    assertEquals(InkState(true, true, true), history.state())
    assertEquals(listOf(first), history.snapshot())
    history.undoMutation()
    assertEquals(InkState(false, true, false), history.state())
    history.redoMutation(); history.clearMutation()
    assertEquals(InkState(true, false, false), history.state())
    history.undoMutation()
    assertEquals(listOf(first), history.snapshot())
  }

  @Test
  fun interleavedInkAndTextUseOneOrderedHistory() {
    val history = InkHistory()
    val first = outline(0f)
    val text = text("text-1", "Hello\nworld", 24.0, 40.0)
    val second = outline(20f)

    history.append(first)
    history.appendText(text)
    history.append(second)

    assertEquals(
      listOf(
        PageContent.Ink(first),
        PageContent.Text(text),
        PageContent.Ink(second),
      ),
      history.contentSnapshot(),
    )
    history.undoMutation()
    history.undoMutation()
    assertEquals(listOf(PageContent.Ink(first)), history.contentSnapshot())
    history.redoMutation()
    assertEquals(
      listOf(PageContent.Ink(first), PageContent.Text(text)),
      history.contentSnapshot(),
    )
  }

  @Test
  fun textEditFontAndDeleteEachHaveIndependentHistoryActions() {
    val history = InkHistory()
    val before = text("text-1", "Hello", 10.0, 20.0)
    val after = text("text-1", "Hello\nworld", 10.0, 20.0, width = 48.0, height = 32.0, fontSize = 18.0)

    history.appendText(before)
    history.replaceText(before, after)
    assertEquals(listOf(PageContent.Text(after)), history.contentSnapshot())
    history.undoMutation()
    assertEquals(listOf(PageContent.Text(before)), history.contentSnapshot())
    history.redoMutation()
    history.removeTextAnnotation(after)
    assertTrue(history.contentSnapshot().isEmpty())
    history.undoMutation()
    assertEquals(listOf(PageContent.Text(after)), history.contentSnapshot())
  }

  @Test
  fun clearAndUndoRestoreInkAndTextTogether() {
    val history = InkHistory()
    val first = outline(0f)
    val text = text("text-1", "Signed", 12.0, 18.0)
    history.append(first)
    history.appendText(text)

    history.clearMutation()
    assertEquals(InkState(true, false, false), history.state())
    history.undoMutation()
    assertEquals(2, history.contentSnapshot().size)
    assertEquals(InkState(true, true, true), history.state())
    history.redoMutation()
    assertTrue(history.contentSnapshot().isEmpty())
  }

  @Test
  fun textSnapshotKeepsCanonicalBoundsAndDoesNotExposeHistoryStorage() {
    val history = InkHistory()
    val annotation = text("text-1", "A\nlongest", 14.0, 22.0, width = 64.0, height = 30.0)
    history.appendText(annotation)

    val snapshot = history.contentSnapshot()
    assertEquals(PagePoint(14.0, 22.0), annotation.position)
    assertEquals(64.0, annotation.intrinsicWidth, 0.0)
    assertEquals(30.0, annotation.intrinsicHeight, 0.0)
    assertEquals(listOf(PageContent.Text(annotation)), snapshot)
    assertEquals(listOf(PageContent.Text(annotation)), history.contentSnapshot())
  }

  @Test
  fun historyOwnsAnImmutableCubicCommandSnapshot() {
    val commands = mutableListOf(
      InkPathCommand(InkPathCommand.MOVE, 4f, 5f),
      InkPathCommand(InkPathCommand.CUBIC, 8f, 9f, 5f, 6f, 7f, 8f),
      InkPathCommand(InkPathCommand.CLOSE),
    )
    val outline = StrokeOutline.fromCommands(commands)
    commands[1] = InkPathCommand(InkPathCommand.CUBIC, 99f, 99f)
    val data = outline.contourPathData.single()
    assertEquals(8f, data.commands[1].x)
    assertEquals(5f, data.commands[1].c1x)
    assertEquals(1, outline.cubicSegmentCount)
  }

  @Test
  fun contourCollectionKeepsIndependentClosedSubpaths() {
    val first = contour(0f)
    val second = contour(20f)
    val outline = StrokeOutline.copyOf(listOf(first, second))
    assertEquals(2, outline.contourPathData.size)
    assertTrue(outline.contourPathData.all { data ->
      data.commands.count { it.type == InkPathCommand.MOVE } == 1 &&
        data.commands.count { it.type == InkPathCommand.CLOSE } == 1
    })
  }

  private fun outline(offset: Float): StrokeOutline = StrokeOutline.fromCommands(listOf(
    InkPathCommand(InkPathCommand.MOVE, offset, 0f),
    InkPathCommand(InkPathCommand.CUBIC, offset + 10f, 0f, offset + 3f, 4f, offset + 7f, -4f),
    InkPathCommand(InkPathCommand.CLOSE),
  ))

  private fun contour(offset: Float) = StrokeContour(listOf(
    StrokeCubicSegment(
      offset, 0f, offset + 3f, 4f, offset + 7f, -4f, offset + 10f, 0f, 0L, 1L,
    ),
    StrokeCubicSegment(
      offset + 10f, 0f, offset + 7f, 4f, offset + 3f, -4f, offset, 0f, 0L, 1L,
    ),
  ), 0L, 1L, true)

  private fun text(
    id: String,
    value: String,
    left: Double,
    top: Double,
    width: Double = 40.0,
    height: Double = 16.0,
    fontSize: Double = 16.0,
  ) = TextAnnotation(
    id = id,
    text = value,
    bounds = PageRect(left, top, left + width, top + height),
    fontSize = fontSize,
  )
}
