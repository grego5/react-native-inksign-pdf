package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.view.MotionEvent
import android.widget.EditText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class TextPlacementInstrumentationTest {
  private lateinit var harness: TextSurfaceHarness

  @Before
  fun setUp() {
    NativeTestRuntime.initialize()
    harness = TextSurfaceHarness()
  }

  @After
  fun tearDown() {
    if (::harness.isInitialized) harness.close()
  }

  @Test
  fun placementOnIsIdempotentAndOffIsIdempotent() {
    harness.runOnMain {
      val overlay = harness.createOverlay()
      overlay.armPlacement(1L)
      overlay.armPlacement(1L)
      assertTrue(overlay.hasPendingPlacement())

      overlay.cancelPendingPlacement()
      overlay.cancelPendingPlacement()
      assertFalse(overlay.hasPendingPlacement())
      overlay.dispose()
    }
  }

  @Test
  fun firstTapConsumesTheStreamAndEmptyDraftDoesNotChangeHistory() {
    harness.runOnMain {
      val overlay = harness.createOverlay()
      overlay.armPlacement(1L)

      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150.0f, 150.0f, 1_000L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150.0f, 150.0f, 1_020L))
      assertFalse(overlay.hasPendingPlacement())
      assertNotNull(overlay.editingAnnotationId())
      assertTrue(
        harness.surface.textPresentationSnapshot()?.annotations.orEmpty().isEmpty(),
      )

      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 290.0f, 290.0f, 1_040L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 290.0f, 290.0f, 1_060L))
      assertTrue(
        harness.surface.textPresentationSnapshot()?.annotations.orEmpty().isEmpty(),
      )
      overlay.dispose()
    }
  }

  @Test
  fun focusLossModeChangeReplacementAndDisposalCancelPendingPlacement() {
    harness.runOnMain {
      val overlay = harness.createOverlay()
      harness.surface.onWindowFocusLost = overlay::cancelPendingPlacement
      overlay.armPlacement(1L)
      harness.surface.onWindowFocusChanged(false)
      assertFalse(overlay.hasPendingPlacement())

      harness.surface.onModeChanged = overlay::cancelPendingPlacement
      overlay.armPlacement(1L)
      harness.surface.setEditMode(true)
      assertFalse(overlay.hasPendingPlacement())

      overlay.armPlacement(1L)
      harness.surface.switchPage(1)
      overlay.syncContent()
      assertFalse(overlay.hasPendingPlacement())

      overlay.armPlacement(1L)
      harness.setDocument(harness.info)
      overlay.syncContent()
      assertFalse(overlay.hasPendingPlacement())

      overlay.armPlacement(1L)
      overlay.dispose()
      assertFalse(overlay.hasPendingPlacement())
    }
  }

  @Test
  fun staleGenerationCannotArmPlacement() {
    harness.runOnMain {
      val overlay = harness.createOverlay()
      assertThrows(PdfSessionException::class.java) {
        overlay.armPlacement(2L)
      }
      assertFalse(overlay.hasPendingPlacement())
      overlay.dispose()
    }
  }

  @Test
  fun committedTextTapEntersEditingAndFontChangeSettlesAsOneReplacement() {
    harness.runOnMain {
      val overlay = harness.createOverlay()
      val original = TextAnnotation(
        id = "text-existing",
        text = "Hello",
        bounds = PageRect(80.0, 80.0, 120.0, 98.0),
        fontSize = 16.0,
      )
      harness.surface.appendTextAnnotation(1L, 0, original)
      overlay.syncContent()
      val point = checkNotNull(harness.surface.textPresentationSnapshot())
        .transform.map(original.position)

      try {
        dispatch(overlay, MotionEvent.ACTION_DOWN, point.x.toFloat(), point.y.toFloat(), 3_000L)
        dispatch(overlay, MotionEvent.ACTION_UP, point.x.toFloat(), point.y.toFloat(), 3_020L)

        assertEquals(InteractionMode.TEXTEDITING, overlay.interactionMode())
        val editor = overlay.getChildAt(0) as EditText
        editor.setSelection(1, 3)
        val result = overlay.increaseTextSize()

        assertEquals(17.0, result, 0.0)
        assertEquals("Hello", editor.text.toString())
        assertEquals(1, editor.selectionStart)
        assertEquals(3, editor.selectionEnd)
        assertEquals(InteractionMode.TEXTEDITING, overlay.interactionMode())

        editor.setText("Updated")
        overlay.finishForLifecycle()
        val updated = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertEquals("Updated", updated.text)
        assertEquals(17.0, updated.fontSize, 0.0)

        harness.surface.undo()
        val undone = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertEquals(original, undone)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun longPressReleaseRetainsSelectionAndOutsideTapClearsIt() {
    lateinit var overlay: TextInteractionOverlay
    var revisionBeforeHold = 0L
    harness.runOnMain {
      overlay = harness.createOverlay()
      val annotation = TextAnnotation(
        id = "text-retained-selection",
        text = "Hello",
        bounds = PageRect(80.0, 80.0, 140.0, 100.0),
        fontSize = 16.0,
      )
      harness.surface.appendTextAnnotation(1L, 0, annotation)
      overlay.syncContent()
      revisionBeforeHold = harness.surface.activeHistory().revision
      val point = checkNotNull(harness.surface.textPresentationSnapshot())
        .transform.map(annotation.position)
      dispatch(overlay, MotionEvent.ACTION_DOWN, point.x.toFloat(), point.y.toFloat(), 3_100L)
    }
    try {
      Thread.sleep(650L)
      harness.runOnMain {
        val point = checkNotNull(harness.surface.textPresentationSnapshot())
          .transform.map(PagePoint(80.0, 80.0))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, point.x.toFloat(), point.y.toFloat(), 3_760L))
        assertEquals(InteractionMode.TEXTSELECTED, overlay.interactionMode())
        assertEquals(null, overlay.editingAnnotationId())
        assertEquals(revisionBeforeHold, harness.surface.activeHistory().revision)
        assertEquals(16.0, checkNotNull(harness.surface.textPresentationSnapshot())
          .annotations.single().fontSize, 0.0)
        assertEquals(17.0, overlay.increaseTextSize(), 0.0)
        assertEquals(InteractionMode.TEXTSELECTED, overlay.interactionMode())
        dispatch(overlay, MotionEvent.ACTION_DOWN, 290.0f, 290.0f, 3_800L)
        dispatch(overlay, MotionEvent.ACTION_UP, 290.0f, 290.0f, 3_820L)
        assertEquals(InteractionMode.VIEW, overlay.interactionMode())
      }
    } finally {
      harness.runOnMain { overlay.dispose() }
    }
  }

  @Test
  fun changedDragCommitsOnceAndCancelledDragRetainsTheCommittedSelection() {
    lateinit var overlay: TextInteractionOverlay
    lateinit var original: TextAnnotation
    lateinit var point: ViewPoint
    harness.runOnMain {
      overlay = harness.createOverlay()
      val created = TextAnnotation(
        id = "text-drag-selection",
        text = "Hello",
        bounds = PageRect(80.0, 80.0, 140.0, 100.0),
        fontSize = 16.0,
      )
      original = created
      harness.surface.appendTextAnnotation(1L, 0, original)
      overlay.syncContent()
      point = checkNotNull(harness.surface.textPresentationSnapshot()).transform.map(original.position)
      dispatch(overlay, MotionEvent.ACTION_DOWN, point.x.toFloat(), point.y.toFloat(), 3_900L)
    }
    try {
      Thread.sleep(650L)
      harness.runOnMain {
        dispatch(overlay, MotionEvent.ACTION_MOVE, point.x.toFloat() + 40f, point.y.toFloat(), 4_560L)
        dispatch(overlay, MotionEvent.ACTION_UP, point.x.toFloat() + 40f, point.y.toFloat(), 4_580L)
        val moved = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertEquals(InteractionMode.TEXTSELECTED, overlay.interactionMode())
        assertTrue(moved.position.x > original.position.x)

        val movedPoint = checkNotNull(harness.surface.textPresentationSnapshot())
          .transform.map(moved.position)
        dispatch(overlay, MotionEvent.ACTION_DOWN, movedPoint.x.toFloat(), movedPoint.y.toFloat(), 4_600L)
      }
      Thread.sleep(650L)
      harness.runOnMain {
        val moved = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        val movedPoint = checkNotNull(harness.surface.textPresentationSnapshot())
          .transform.map(moved.position)
        dispatch(overlay, MotionEvent.ACTION_CANCEL, movedPoint.x.toFloat(), movedPoint.y.toFloat(), 5_260L)
        assertEquals(InteractionMode.TEXTSELECTED, overlay.interactionMode())
        assertEquals(moved, checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single())
      }
    } finally {
      harness.runOnMain { overlay.dispose() }
    }
  }

  @Test
  fun outsideEditorDragPansViewportAndKeepsEditorActive() {
    harness.runOnMain {
      harness.surface.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 5_600L))
        assertEquals(InteractionMode.TEXTEDITING, overlay.interactionMode())
        val before = harness.surface.currentViewportState().focus

        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 290f, 290f, 5_620L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_MOVE, 240f, 290f, 5_640L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 240f, 290f, 5_660L))

        assertEquals(InteractionMode.TEXTEDITING, overlay.interactionMode())
        assertEquals(1, overlay.childCount)
        assertTrue(harness.surface.currentViewportState().focus.x != before.x)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun mountedRtlEditorKeepsItsRightEdgeAcrossTypingAndDeletion() {
    harness.runOnMain {
      harness.surface.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 5_000L))
        val editor = overlay.getChildAt(0) as EditText
        assertTrue(editor.paddingLeft > 0)
        assertTrue(editor.paddingTop > 0)
        overlay.syncTransform()
        val beforeTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val beforeRight = beforeTransform.inverse()
          .map(PagePoint(editor.right.toDouble(), editor.top.toDouble())).x

        editor.setText("ש")
        overlay.syncTransform()
        val afterTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val afterRight = afterTransform.inverse()
          .map(PagePoint(editor.right.toDouble(), editor.top.toDouble())).x

        assertEquals(beforeRight, afterRight, 2.0)
        assertEquals(16.0 * afterTransform.uniformScale()!!, editor.textSize.toDouble(), 0.01)
        editor.setText("")
        overlay.syncTransform()
        val emptiedTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val emptiedRight = emptiedTransform.inverse()
          .map(PagePoint(editor.right.toDouble(), editor.top.toDouble())).x
        assertEquals(afterRight, emptiedRight, 2.0)
        editor.setText("שלום".repeat(40))
        overlay.syncTransform()
        val layout = checkNotNull(editor.layout)
        assertTrue(layout.lineCount > 1)
        val finalCaretX = layout.getPrimaryHorizontal(editor.text.length)
        assertTrue(finalCaretX >= -1f && finalCaretX <= editor.width + 1f)
        val wideWidth = editor.width
        editor.setText("")
        overlay.syncTransform()
        assertTrue(editor.width > 0 && editor.width < wideWidth)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun nativeSoftWrapsBecomeExplicitTextWhenTheDraftSettles() {
    harness.runOnMain {
      harness.surface.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 6_000L))
        val editor = overlay.getChildAt(0) as EditText
        editor.setText("abcdefghij".repeat(80))
        overlay.syncTransform()
        val nativeLineCount = checkNotNull(editor.layout).lineCount
        assertTrue(nativeLineCount > 1)

        overlay.finishForLifecycle()

        val annotation = checkNotNull(harness.surface.textPresentationSnapshot())
          .annotations.single()
        assertEquals(nativeLineCount, annotation.text.count { it == '\n' } + 1)
        assertTrue(!annotation.text.contains("\n\n"))
        assertEquals(
          TextLayoutSpec.measure(annotation.text, annotation.fontSize).height,
          annotation.intrinsicHeight,
          0.01,
        )
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun selectionVisibilityFollowsTheMovedRangeEndpoint() {
    harness.runOnMain {
      harness.surface.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 7_000L))
        val editor = overlay.getChildAt(0) as EditText
        val text = "A".repeat(220)
        editor.setText(text)
        overlay.syncTransform()

        editor.setSelection(0, text.length)
        overlay.syncTransform()
        val endFocus = harness.surface.currentViewportState().focus.x
        assertCaretIsInsideView(editor, editor.selectionEnd)

        editor.setSelection(1, text.length)
        overlay.syncTransform()
        val startFocus = harness.surface.currentViewportState().focus.x
        assertTrue(startFocus < endFocus)
        assertCaretIsInsideView(editor, editor.selectionStart)

        editor.setSelection(1)
        overlay.syncTransform()
        assertCaretIsInsideView(editor, editor.selectionStart)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun movementBeyondTouchSlopDoesNotSelectOrEditText() {
    harness.runOnMain {
      val overlay = harness.createOverlay()
      val annotation = TextAnnotation(
        id = "text-moved-touch",
        text = "Hello",
        bounds = PageRect(80.0, 80.0, 140.0, 100.0),
        fontSize = 16.0,
      )
      harness.surface.appendTextAnnotation(1L, 0, annotation)
      overlay.syncContent()
      val point = checkNotNull(harness.surface.textPresentationSnapshot())
        .transform.map(annotation.position)

      try {
        dispatch(overlay, MotionEvent.ACTION_DOWN, point.x.toFloat(), point.y.toFloat(), 4_000L)
        dispatch(overlay, MotionEvent.ACTION_MOVE, point.x.toFloat() + 40f, point.y.toFloat(), 4_020L)
        dispatch(overlay, MotionEvent.ACTION_UP, point.x.toFloat() + 40f, point.y.toFloat(), 4_040L)

        assertEquals(InteractionMode.VIEW, overlay.interactionMode())
        assertEquals(0, overlay.childCount)
      } finally {
        overlay.dispose()
      }
    }
  }

  private fun dispatch(
    overlay: TextInteractionOverlay,
    action: Int,
    x: Float,
    y: Float,
    time: Long,
  ): Boolean {
    val event = MotionEvent.obtain(time, time, action, x, y, 0)
    return try {
      overlay.onTouchEvent(event)
    } finally {
      event.recycle()
    }
  }

  private fun assertCaretIsInsideView(editor: EditText, offset: Int) {
    val layout = checkNotNull(editor.layout)
    val line = layout.getLineForOffset(offset)
    val caretX = editor.left + editor.paddingLeft +
      layout.getPrimaryHorizontal(offset).toInt() - editor.scrollX
    val caretTop = editor.top + editor.paddingTop + layout.getLineTop(line) - editor.scrollY
    assertTrue(caretX >= 8)
    assertTrue(caretX <= 292)
    assertTrue(caretTop >= 8)
    assertTrue(caretTop <= 292)
  }

  private inner class TextSurfaceHarness {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val worker = PdfSessionWorker(
      opener = PdfSessionOpener { _, generation ->
        EmptyPdfResource(info.copy(generation = generation))
      },
    )
    private val engine = StrokeEngine()
    lateinit var surface: SurfaceView
    val info = PdfSessionInfo(
      sourcePath = "text.pdf",
      pages = listOf(
        PdfPageDimensions(300.0, 300.0),
        PdfPageDimensions(300.0, 300.0),
      ),
      generation = 1L,
    )

    init {
      val created = java.util.concurrent.atomic.AtomicReference<SurfaceView>()
      instrumentation.runOnMainSync {
        created.set(SurfaceView(instrumentation.targetContext, worker, engine))
        surface = created.get()
        surface.layout(0, 0, 300, 300)
      }
      val result = java.util.concurrent.atomic.AtomicReference<Result<PdfSessionInfo>>()
      val completed = CountDownLatch(1)
      worker.replace("text.pdf", 1L) {
        result.set(it)
        completed.countDown()
      }
      assertTrue(completed.await(5L, TimeUnit.SECONDS))
      runOnMain { surface.setDocument(result.get().getOrThrow()) }
    }

    fun createOverlay(): TextInteractionOverlay {
      val overlay = TextInteractionOverlay(instrumentation.targetContext, surface)
      surface.onTextContentChanged = overlay::syncContent
      surface.onTextTransformChanged = overlay::syncTransform
      overlay.layout(0, 0, 300, 300)
      overlay.syncContent()
      return overlay
    }

    fun setDocument(next: PdfSessionInfo) {
      surface.setDocument(next)
    }

    fun runOnMain(action: () -> Unit) = instrumentation.runOnMainSync(action)

    fun close() {
      runOnMain { surface.clearDocument() }
      engine.close()
      worker.close()
    }
  }

  private class EmptyPdfResource(
    override val info: PdfSessionInfo,
  ) : PdfSessionResource {
    override fun renderTiles(
      requests: List<PdfTileRequest>,
      beforeEach: () -> Unit,
    ): List<PdfTile> = emptyList()

    override fun renderPreview(
      request: PdfTileRequest,
      beforeRender: () -> Unit,
    ): PdfTile {
      beforeRender()
      return PdfTile(
        request,
        Bitmap.createBitmap(request.widthPx, request.heightPx, Bitmap.Config.ARGB_8888),
      )
    }

    override fun close() = Unit
  }
}
