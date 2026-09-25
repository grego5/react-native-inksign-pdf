package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.view.MotionEvent
import android.widget.EditText
import android.widget.TextView
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
      revisionBeforeHold = harness.activeHistoryRevision()
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
        assertEquals(revisionBeforeHold, harness.activeHistoryRevision())
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
  fun selectedTextDragsFromItsPaddedOutlineAndAStationaryTapEdits() {
    for (isRtl in listOf(false, true)) {
      lateinit var overlay: TextInteractionOverlay
      val annotationId = if (isRtl) "text-selected-rtl" else "text-selected-ltr"
      harness.runOnMain {
        overlay = harness.createOverlay()
        val annotation = TextAnnotation(
          id = annotationId,
          text = "Selected",
          bounds = PageRect(80.0, 80.0, 150.0, 102.0),
          fontSize = 16.0,
          directionRtl = isRtl,
        )
        harness.surface.appendTextAnnotation(1L, 0, annotation)
        overlay.syncContent()
        val transform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val point = transform.map(annotation.position)
        assertTrue(dispatch(
          overlay,
          MotionEvent.ACTION_DOWN,
          point.x.toFloat(),
          point.y.toFloat(),
          3_300L,
        ))
      }
      try {
        Thread.sleep(650L)
        harness.runOnMain {
          val snapshot = checkNotNull(harness.surface.textPresentationSnapshot())
          val original = snapshot.annotations.single { it.id == annotationId }
          val originalPoint = snapshot.transform.map(original.position)
          assertTrue(dispatch(
            overlay,
            MotionEvent.ACTION_UP,
            originalPoint.x.toFloat(),
            originalPoint.y.toFloat(),
            3_960L,
          ))
          assertEquals(InteractionMode.TEXTSELECTED, overlay.interactionMode())
          val revisionBeforeMove = harness.activeHistoryRevision()

          val scale = snapshot.transform.uniformScale() ?: 1.0
          val horizontalPadding = textEditorPaddingPx(
            original.fontSize * scale,
            textEditorHorizontalPaddingRatio,
          ).toFloat()
          val verticalPadding = textEditorPaddingPx(
            original.fontSize * scale,
            textEditorVerticalPaddingRatio,
          ).toFloat()
          val outer = textAnnotationOuterRect(
            original.bounds,
            snapshot.transform,
            horizontalPadding,
            verticalPadding,
          )
          val downX = if (isRtl) outer.right - 1f else outer.left + 1f
          val downY = (outer.top + outer.bottom) / 2f
          val downTime = if (isRtl) 4_000L else 3_980L
          assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, downX, downY, downTime))
          assertTrue(dispatch(
            overlay,
            MotionEvent.ACTION_MOVE,
            downX + 40f,
            downY,
            downTime + 20L,
          ))
          assertTrue(dispatch(
            overlay,
            MotionEvent.ACTION_UP,
            downX + 40f,
            downY,
            downTime + 40L,
          ))
          val moved = checkNotNull(harness.surface.textPresentationSnapshot())
            .annotations.single { it.id == annotationId }
          assertEquals(InteractionMode.TEXTSELECTED, overlay.interactionMode())
          assertTrue(moved.position.x > original.position.x)
          assertEquals(revisionBeforeMove + 1L, harness.activeHistoryRevision())

          val movedPresentation = checkNotNull(harness.surface.textPresentationSnapshot())
          val movedOuter = textAnnotationOuterRect(
            moved.bounds,
            movedPresentation.transform,
            horizontalPadding,
            verticalPadding,
          )
          val tapX = if (isRtl) movedOuter.right - 1f else movedOuter.left + 1f
          val tapY = (movedOuter.top + movedOuter.bottom) / 2f
          assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tapX, tapY, downTime + 60L))
          assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tapX, tapY, downTime + 80L))
          assertEquals(InteractionMode.TEXTEDITING, overlay.interactionMode())
          assertEquals(1, editorCount(overlay))
          assertEquals(revisionBeforeMove + 1L, harness.activeHistoryRevision())
        }
      } finally {
        harness.runOnMain { overlay.dispose() }
      }
    }
  }

  @Test
  fun outsideEditorDragPansViewportAndKeepsEditorActive() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 5_600L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, 5_610L))
        assertEquals(InteractionMode.TEXTEDITING, overlay.interactionMode())
        assertEquals(1, editorCount(overlay))
        val editor = editorView(overlay)
        val panStartX = 8f
        val panStartY = 2f
        assertTrue(
          "The pan gesture must start outside the editor; editor=" +
            "[${editor.left},${editor.top},${editor.right},${editor.bottom}]",
            panStartX < editor.left || panStartX > editor.right ||
            panStartY < editor.top || panStartY > editor.bottom,
        )
        val before = harness.surface.currentViewportState().focus

        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, panStartX, panStartY, 5_620L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_MOVE, panStartX + 50f, panStartY, 5_640L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, panStartX + 50f, panStartY, 5_660L))

        assertEquals(InteractionMode.TEXTEDITING, overlay.interactionMode())
        assertEquals(1, editorCount(overlay))
        assertTrue(harness.surface.currentViewportState().focus.x != before.x)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun mountedRtlEditorKeepsItsRightEdgeAcrossTypingAndDeletion() {
    harness.runOnMain {
        harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
        val overlay = harness.createOverlay()
      try {
        overlay.setTextDirection(TextDirection.RTL)
        overlay.armPlacement(1L)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 5_000L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, 5_010L))
        assertEquals(InteractionMode.TEXTEDITING, overlay.interactionMode())
        assertEquals(1, editorCount(overlay))
        val editor = editorView(overlay)
        assertTrue(editor.paddingLeft > 0)
        assertTrue(editor.paddingTop > 0)
        overlay.syncTransform()
        val beforeTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val beforeRight = beforeTransform.inverse()
          .map(PagePoint(editor.right.toDouble(), editor.top.toDouble())).x

        editor.setText("1")
        overlay.syncTransform()
        val oneTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val oneRight = oneTransform.inverse()
          .map(PagePoint(editor.right.toDouble(), editor.top.toDouble())).x
        assertEquals(beforeRight, oneRight, 2.0)

        editor.setText("Latin")
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
        editor.setText("1Latin שלום")
        overlay.finishForLifecycle()
        assertTrue(checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single().directionRtl)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun autoDirectionResamplesOnlyWhileEmptyAndPersistsWhenReopened() {
    var keyboardRtl: Boolean? = true
    harness.runOnMain {
      val overlay = harness.createOverlay { keyboardRtl }
      try {
        overlay.armPlacement(1L)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 5_500L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, 5_510L))
        val editor = editorView(overlay)
        assertEquals(TextView.TEXT_DIRECTION_RTL, editor.textDirection)

        val revisionBeforeTyping = harness.activeHistoryRevision()
        keyboardRtl = false
        editor.setText("1")
        assertEquals(TextView.TEXT_DIRECTION_LTR, editor.textDirection)

        keyboardRtl = true
        editor.setText("1Latin שלום")
        editor.setSelection(editor.text.length)
        assertEquals(TextView.TEXT_DIRECTION_LTR, editor.textDirection)

        editor.setText("")
        assertEquals(TextView.TEXT_DIRECTION_RTL, editor.textDirection)
        assertEquals(revisionBeforeTyping, harness.activeHistoryRevision())

        editor.setText("1Latin שלום")
        keyboardRtl = false
        editor.setSelection(0)
        assertEquals(TextView.TEXT_DIRECTION_RTL, editor.textDirection)
        overlay.finishForLifecycle()

        val saved = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertTrue(saved.directionRtl)
        val savedRevision = harness.activeHistoryRevision()
        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        val tap = presentation.transform.map(
          PagePoint(
            (saved.bounds.left + saved.bounds.right) / 2.0,
            (saved.bounds.top + saved.bounds.bottom) / 2.0,
          ),
        )
        assertTrue(
          dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 5_520L),
        )
        assertTrue(
          dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 5_530L),
        )

        val reopened = editorView(overlay)
        assertEquals(TextView.TEXT_DIRECTION_RTL, reopened.textDirection)
        assertEquals(saved.text, reopened.text.toString())
        assertEquals(savedRevision, harness.activeHistoryRevision())
        assertEquals(saved, checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single())
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun explicitDirectionOverridesKeyboardLanguageForNewText() {
    harness.runOnMain {
      listOf(TextDirection.LTR to true, TextDirection.RTL to false).forEachIndexed { index, pair ->
        val (direction, keyboardRtl) = pair
        val overlay = harness.createOverlay { keyboardRtl }
        try {
          overlay.setTextDirection(direction)
          overlay.armPlacement(1L)
          val x = if (index == 0) 80f else 220f
          val time = 5_600L + index * 40L
          assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, x, 80f, time))
          assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, x, 80f, time + 10L))
          val editor = editorView(overlay)
          editor.setText("1")
          val expectedRtl = direction == TextDirection.RTL
          assertEquals(
            if (expectedRtl) TextView.TEXT_DIRECTION_RTL else TextView.TEXT_DIRECTION_LTR,
            editor.textDirection,
          )
          overlay.finishForLifecycle()
          assertEquals(
            expectedRtl,
            checkNotNull(harness.surface.textPresentationSnapshot()).annotations.last().directionRtl,
          )
        } finally {
          overlay.dispose()
        }
      }
    }
  }

  @Test
  fun nativeSoftWrapsBecomeExplicitTextWhenTheDraftSettles() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        choosePlacementDirection(overlay, rtl = false)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 6_000L))
        val editor = editorView(overlay)
        editor.setText("abcdefghij".repeat(80))
        overlay.syncTransform()
        val nativeLayout = checkNotNull(editor.layout)
        val nativeLineCount = nativeLayout.lineCount
        val pageScale = checkNotNull(harness.surface.textPresentationSnapshot())
          .transform.uniformScale() ?: error("Text viewport must have a uniform scale")
        val nativeHeightInPageUnits = nativeLayout.height / pageScale
        assertTrue(nativeLineCount > 1)

        overlay.finishForLifecycle()

        val annotation = checkNotNull(harness.surface.textPresentationSnapshot())
          .annotations.single()
        assertEquals(nativeLineCount, annotation.text.count { it == '\n' } + 1)
        assertTrue(!annotation.text.contains("\n\n"))
        assertEquals(
          nativeHeightInPageUnits,
          annotation.intrinsicHeight,
          0.01,
        )
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun measuredEmptyEditorFrameBottomMatchesTap() {
    lateinit var overlay: TextInteractionOverlay
    lateinit var pageTap: PagePoint
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, focus = PagePoint(150.0, 150.0), fitToPage = false)
      overlay = harness.createOverlay()
      choosePlacementDirection(overlay, rtl = false)
      overlay.armPlacement(1L)
      val initialTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
      val inverseTap = initialTransform.inverse().map(PagePoint(150.0, 150.0))
      pageTap = PagePoint(inverseTap.x, inverseTap.y)
      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 6_500L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, 6_510L))
    }
    try {
      harness.waitForViewportAnimationToFinish()
      harness.runOnMain {
        val editor = editorView(overlay)
        val layout = checkNotNull(editor.layout)
        val emptyContentWidth = editor.width - editor.compoundPaddingLeft - editor.compoundPaddingRight
        assertEquals(editor.textSize, emptyContentWidth.toFloat(), 1.5f)
        val tapInView = checkNotNull(harness.surface.textPresentationSnapshot())
          .transform.map(pageTap)
        val caretX = editor.left + editor.paddingLeft + layout.getPrimaryHorizontal(0)
        assertEquals(tapInView.x.toFloat(), caretX, 1f)
        assertEquals(tapInView.y.toFloat(), editor.bottom.toFloat(), 1f)
      }
    } finally {
      harness.runOnMain { overlay.dispose() }
    }
  }

  @Test
  fun measuredEmptyEditorFrameClampsToPageTopWhenTapIsNearTopEdge() {
    lateinit var overlay: TextInteractionOverlay
    val pageTap = PagePoint(150.0, 5.0)
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, focus = PagePoint(150.0, 20.0), fitToPage = false)
      overlay = harness.createOverlay()
      choosePlacementDirection(overlay, rtl = false)
      overlay.armPlacement(1L)
      val transform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
      val tap = transform.map(pageTap)
      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 6_600L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 6_610L))
    }
    try {
      harness.waitForViewportAnimationToFinish()
      harness.runOnMain {
        val editor = editorView(overlay)
        val transform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val inverse = transform.inverse()
        val frameTop = inverse.map(PagePoint(editor.left.toDouble(), editor.top.toDouble())).y
        val frameBottom = inverse.map(PagePoint(editor.left.toDouble(), editor.bottom.toDouble())).y
        assertEquals(0.0, frameTop, 1.0)
        assertTrue(frameBottom > pageTap.y)
        assertTrue(frameBottom <= 300.0)
      }
    } finally {
      harness.runOnMain { overlay.dispose() }
    }
  }

  @Test
  fun selectionVisibilityFollowsTheMovedRangeEndpoint() {
    lateinit var overlay: TextInteractionOverlay
    lateinit var pageAnchor: PagePoint
    var initialZoom = 0.0
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      overlay = harness.createOverlay()
      overlay.setTextDirection(TextDirection.LTR)
      overlay.armPlacement(1L)
      val initialTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
      val inverseTap = initialTransform.inverse().map(PagePoint(150.0, 150.0))
      pageAnchor = PagePoint(inverseTap.x, inverseTap.y)
      initialZoom = harness.surface.currentViewportState().zoom
      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 7_000L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, 7_010L))
      assertEquals(InteractionMode.TEXTEDITING, overlay.interactionMode())
      assertEquals(1, editorCount(overlay))
    }
    try {
      harness.waitForViewportAnimationToFinish()
      harness.runOnMain {
        val editor = editorView(overlay)
        editor.setText("שלום")
        overlay.syncTransform()
        assertEquals(initialZoom, harness.surface.currentViewportState().zoom, 0.0)
        val hebrewTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val leftAnchorWithHebrew = hebrewTransform.inverse()
          .map(PagePoint(editor.left.toDouble(), editor.top.toDouble())).x

        val text = "A".repeat(12)
        editor.setText(text)
        overlay.syncTransform()
        assertEquals(initialZoom, harness.surface.currentViewportState().zoom, 0.0)
        val latinTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val leftAnchorWithLatin = latinTransform.inverse()
          .map(PagePoint(editor.left.toDouble(), editor.top.toDouble())).x
        assertEquals(leftAnchorWithHebrew, leftAnchorWithLatin, 2.0)

        editor.setSelection(0, text.length)
        overlay.syncTransform()
        assertEquals(initialZoom, harness.surface.currentViewportState().zoom, 0.0)
        val endFocus = harness.surface.currentViewportState().focus.x
        assertCaretIsInsideView(editor, editor.selectionEnd)

        editor.setSelection(1, text.length)
        assertCaretIsOutsideView(editor, editor.selectionStart)
        overlay.syncTransform()
        val startFocus = harness.surface.currentViewportState().focus.x
        assertTrue(startFocus < endFocus)
        assertCaretIsInsideView(editor, editor.selectionStart)

        editor.setSelection(1)
        overlay.syncTransform()
        assertCaretIsInsideView(editor, editor.selectionStart)
        overlay.finishForLifecycle()
        val annotation = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertTrue(!annotation.directionRtl)
        assertEquals(pageAnchor.x, annotation.position.x, 1.0)
        assertEquals(pageAnchor.y, annotation.position.y, 1.0)
        assertEquals(initialZoom, harness.surface.currentViewportState().zoom, 0.0)
      }
    } finally {
      harness.runOnMain { overlay.dispose() }
    }
  }

  @Test
  fun movementBeyondTouchSlopDoesNotSelectOrEditText() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 3.0, focus = PagePoint(80.0, 80.0), fitToPage = false)
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
      val focusBeforeDrag = harness.surface.currentViewportState().focus

      try {
        dispatch(overlay, MotionEvent.ACTION_DOWN, point.x.toFloat(), point.y.toFloat(), 4_000L)
        dispatch(overlay, MotionEvent.ACTION_MOVE, point.x.toFloat() + 40f, point.y.toFloat(), 4_020L)
        dispatch(overlay, MotionEvent.ACTION_UP, point.x.toFloat() + 40f, point.y.toFloat(), 4_040L)

        assertEquals(InteractionMode.VIEW, overlay.interactionMode())
        assertEquals(0, editorCount(overlay))
        assertTrue(harness.surface.currentViewportState().focus != focusBeforeDrag)
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

  private fun editorCount(overlay: TextInteractionOverlay): Int =
    (0 until overlay.childCount).count { overlay.getChildAt(it) is EditText }

  private fun editorView(overlay: TextInteractionOverlay): EditText =
    (0 until overlay.childCount)
      .map(overlay::getChildAt)
      .filterIsInstance<EditText>()
      .single()

  private fun choosePlacementDirection(overlay: TextInteractionOverlay, rtl: Boolean) {
    overlay.setTextDirection(if (rtl) TextDirection.RTL else TextDirection.LTR)
  }

  private fun assertCaretIsInsideView(editor: EditText, offset: Int) {
    val (caretX, caretTop) = caretViewPosition(editor, offset)
    val layout = checkNotNull(editor.layout)
    val focus = harness.surface.currentViewportState().focus
    val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
    val marginPx = 24f * density
    val adjacentOffset = when {
      offset > 0 -> offset - 1
      offset < (editor.text?.length ?: 0) -> offset + 1
      else -> offset
    }
    val adjacentX = editor.left + editor.paddingLeft +
      layout.getPrimaryHorizontal(adjacentOffset).toInt() - editor.scrollX
    val outlineLeft = minOf(caretX, adjacentX) - editor.paddingLeft
    val outlineRight = maxOf(caretX, adjacentX) + editor.paddingRight
    val line = layout.getLineForOffset(offset)
    val outlineTop = caretTop - editor.paddingTop
    val outlineBottom = editor.top + editor.paddingTop + layout.getLineBottom(line) - editor.scrollY +
      editor.paddingBottom
    val details = "caret=($caretX,$caretTop) offset=$offset line=${layout.getLineForOffset(offset)} " +
      "outline=[$outlineLeft,$outlineTop,$outlineRight,$outlineBottom] " +
      "margin=$marginPx editor=[${editor.left},${editor.top},${editor.right},${editor.bottom}] " +
      "scroll=(${editor.scrollX},${editor.scrollY}) focus=(${focus.x},${focus.y})"
    assertTrue("Caret and adjacent outline must be inside the 24 dp margin; $details", outlineLeft >= marginPx)
    assertTrue("Caret and adjacent outline must be inside the 24 dp margin; $details", outlineRight <= 300 - marginPx)
    assertTrue("Caret and adjacent outline must be inside the 24 dp margin; $details", outlineTop >= marginPx)
    assertTrue("Caret and adjacent outline must be inside the 24 dp margin; $details", outlineBottom <= 300 - marginPx)
  }

  private fun assertCaretIsOutsideView(editor: EditText, offset: Int) {
    val (caretX, caretTop) = caretViewPosition(editor, offset)
    val marginPx = 24f * InstrumentationRegistry.getInstrumentation()
      .targetContext.resources.displayMetrics.density
    assertTrue(
      "The moved selection endpoint must start outside the 24 dp margin, got x=$caretX y=$caretTop",
      caretX < marginPx || caretX > 300 - marginPx || caretTop < marginPx || caretTop > 300 - marginPx,
    )
  }

  private fun caretViewPosition(editor: EditText, offset: Int): Pair<Int, Int> {
    val layout = checkNotNull(editor.layout)
    val line = layout.getLineForOffset(offset)
    val caretX = editor.left + editor.paddingLeft +
      layout.getPrimaryHorizontal(offset).toInt() - editor.scrollX
    val caretTop = editor.top + editor.paddingTop + layout.getLineTop(line) - editor.scrollY
    return caretX to caretTop
  }

  private inner class TextSurfaceHarness {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val pages = listOf(
      PdfPageDimensions(300.0, 300.0),
      PdfPageDimensions(300.0, 300.0),
    )
    private val worker = PdfSessionWorker(
      opener = PdfSessionOpener { path, openedGeneration ->
        EmptyPdfResource(PdfSessionInfo(path, pages, openedGeneration))
      },
    )
    private val generation = worker.reserveOpenAttemptId(0L)
    private val engine = InkEngine()
    private val coordinator = MutableDocumentCoordinator(
      generation = generation,
      sessionWorker = worker,
      artifactPolicy = CacheArtifactPolicy.initialize(instrumentation.targetContext),
    )
    fun activeHistoryRevision(): Long = coordinator.activeHistoryRevision()
    lateinit var surface: SurfaceView
    val info = PdfSessionInfo(
      sourcePath = "text.pdf",
      pages = pages,
      generation = generation,
    )

    init {
      val created = java.util.concurrent.atomic.AtomicReference<SurfaceView>()
      instrumentation.runOnMainSync {
        created.set(
          SurfaceView(
            instrumentation.targetContext,
            engine,
            documentCoordinator = coordinator,
          ),
        )
        surface = created.get()
        surface.layout(0, 0, 300, 300)
      }
      val result = java.util.concurrent.atomic.AtomicReference<Result<PdfSessionInfo>>()
      val completed = CountDownLatch(1)
      worker.prepareOpen(generation, "text.pdf", null) { prepared ->
        result.set(prepared)
        assertTrue(worker.commitPreparedOpen(generation) { committed ->
          if (committed.isFailure) result.set(Result.failure(checkNotNull(committed.exceptionOrNull())))
          completed.countDown()
        })
      }
      assertTrue(completed.await(5L, TimeUnit.SECONDS))
      runOnMain { setDocument(result.get().getOrThrow()) }
    }

    fun createOverlay(
      inputLanguageDirectionProvider: (() -> Boolean?)? = null,
    ): TextInteractionOverlay {
      val overlay = TextInteractionOverlay(
        instrumentation.targetContext,
        surface,
        inputLanguageDirectionProvider,
      )
      surface.onTextContentChanged = overlay::syncContent
      surface.onTextTransformChanged = overlay::syncTransform
      overlay.layout(0, 0, 300, 300)
      overlay.syncContent()
      return overlay
    }

    fun setDocument(
      next: PdfSessionInfo,
      zoom: Double? = null,
      focus: PagePoint? = null,
      fitToPage: Boolean = true,
    ) {
      val pages = next.pages.map(::InkPageState)
      surface.documentCoordinator.installCandidate(next.sourcePath, pages, pages.first().id)
      surface.installDocumentPresentation(zoom, focus, fitToPage)
    }

    fun runOnMain(action: () -> Unit) = instrumentation.runOnMainSync(action)

    fun waitForViewportAnimationToFinish(timeoutMs: Long = 5_000L) {
      val deadline = android.os.SystemClock.uptimeMillis() + timeoutMs
      while (android.os.SystemClock.uptimeMillis() < deadline) {
        val animating = java.util.concurrent.atomic.AtomicBoolean()
        instrumentation.runOnMainSync { animating.set(surface.isTextFocusAnimating()) }
        if (!animating.get()) return
        android.os.SystemClock.sleep(16L)
      }
      throw AssertionError("Text focus animation did not settle before the selection visibility check")
    }

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
