package com.margelo.nitro.inksignpdf

import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Rect
import android.text.SpannableString
import android.text.Spanned
import android.text.style.UnderlineSpan
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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
  fun programmaticTextUsesCanonicalPositionWithoutOpeningEditor() {
    harness.runOnMain {
      harness.setDocument(
        harness.info,
        zoom = 1.0,
        focus = PagePoint(150.0, 150.0),
        fitToPage = false,
      )
      val overlay = harness.createOverlay()

      harness.insertText(TextAnnotationBounds(20.0, 30.0, 280.0, 270.0), "Approved", null)

      val annotation = harness.surface.textPresentationSnapshot()?.annotations?.single()
      assertNotNull(annotation)
      assertEquals("Approved", annotation?.text)
      assertEquals(20.0, annotation?.bounds?.left ?: -1.0, 0.0)
      assertEquals(30.0, annotation?.bounds?.top ?: -1.0, 0.0)
      assertEquals(PageRect(20.0, 30.0, 300.0, 300.0), annotation?.flowBounds)
      assertFalse(annotation?.directionRtl ?: true)
      assertEquals(InteractionMode.VIEW, overlay.interactionMode())
      assertEquals(0, editorCount(overlay))
      overlay.dispose()
    }
  }

  @Test
  fun emptyTextEditHidesEmbeddedValueAndRetainsCapturedOptions() {
    harness.runOnMain {
      val page = harness.core.state.pageMetadata(0)
      val context = DocumentPageContext(harness.core.state.generation, page.id)
      val slot = harness.coordinator.reserveTextTarget(
        pageId = page.id,
        sourceIdentity = "transaction-test",
        fieldName = "Name",
        canonicalBounds = PageRect(20.0, 30.0, 200.0, 60.0),
        options = null,
        embeddedValue = "embedded value",
      )
      val edit = harness.core.beginTextEdit(context, slot.id)
      val captured = TextAnnotationOptions(
        untracked = null,
        font = null,
        fontSize = 18.0,
        color = "#123456",
        direction = TextDirection.RTL,
        maxLines = null,
        alignment = null,
        verticalAnchor = null,
      )

      harness.core.updateTextEdit(edit, null, captured)
      assertEquals("The live empty edit masks the embedded fallback", "", harness.core.text.getValue(context, slot.id.toDouble()))
      assertEquals("The target reports the live value", "", harness.core.text.getEntry(context, slot.id.toDouble()).value)

      harness.core.endTextEdit(slot.id)
      assertEquals("Embedded text returns after the transaction ends", "embedded value",
        harness.core.text.getValue(context, slot.id.toDouble()))
      harness.core.text.setValue(context, slot.id.toDouble(), "replacement", null)
      val annotation = checkNotNull(harness.coordinator.pageSnapshot(0).content
        .single().textAnnotationOrNull())
      assertEquals(18.0, annotation.fontSize, 0.0)
      assertEquals(android.graphics.Color.rgb(0x12, 0x34, 0x56), annotation.textColor)
      assertTrue(annotation.directionRtl)
    }
  }

  @Test
  fun rejectedSameTargetWritesPreserveTheActiveDraftAndHistory() {
    harness.runOnMain {
      val page = harness.core.state.pageMetadata(0)
      val context = DocumentPageContext(harness.core.state.generation, page.id)
      val baseline = harness.core.text.insert(
        context, TextAnnotationBounds(20.0, 30.0, 200.0, 60.0), "before", null,
      )
      val edit = harness.core.beginTextEdit(context, baseline.id)
      harness.core.updateTextEdit(edit, baseline.copy(text = "draft"))
      val revision = harness.coordinator.pageHistoryRevision(0)
      val history = harness.coordinator.pageHistoryState(0)
      var ended = 0
      val subscription = harness.core.observe { if (it is DocumentChange.EditEnded) ended += 1 }
      try {
        val invalid = TextAnnotationOptions(
          untracked = null, font = Variant_NullType_String.create("not-loaded"),
          fontSize = null, color = null, direction = null, maxLines = null,
          alignment = null, verticalAnchor = null,
        )
        val writes = listOf<() -> Unit>(
          { harness.core.text.setValue(context, baseline.id.toDouble(), "replacement", invalid) },
          { harness.core.text.setOptions(context, baseline.id.toDouble(), invalid) },
        )
        for (write in writes) {
          val error = assertThrows(PdfSessionException::class.java) { write() }
          assertEquals("font_not_loaded", error.code)
          assertTrue(harness.core.activeTextEdit === edit)
          assertTrue(edit.active)
          assertEquals("draft", harness.core.text.getValue(context, baseline.id.toDouble()))
          assertEquals(revision, harness.coordinator.pageHistoryRevision(0))
          assertEquals(history, harness.coordinator.pageHistoryState(0))
          assertEquals(0, ended)
        }
        harness.core.text.setValue(context, baseline.id.toDouble(), "accepted", null)
        assertFalse(edit.active)
        assertEquals(1, ended)
        harness.core.undo(page.id)
        assertEquals("draft", harness.core.text.getValue(context, baseline.id.toDouble()))
        harness.core.undo(page.id)
        assertEquals("before", harness.core.text.getValue(context, baseline.id.toDouble()))
      } finally { subscription.close() }
    }
  }

  @Test
  fun emptyEditorRetainsItsColorWhenTheTargetIsRepopulated() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.setDefaultTextColor("#123456")
        overlay.armPlacement(harness.core.state.generation)
        val tap = checkNotNull(harness.surface.textPresentationSnapshot()).transform.map(PagePoint(150.0, 150.0))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 1_100L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 1_110L))
        val edit = checkNotNull(harness.core.activeTextEdit)
        editorView(overlay).setText("colored")
        editorView(overlay).setText("")
        overlay.finishForLifecycle()

        harness.core.text.setValue(edit.context, edit.id.toDouble(), "replacement", null)
        val annotation = checkNotNull(harness.coordinator.pageSnapshot(0).content.single().textAnnotationOrNull())
        assertEquals(android.graphics.Color.rgb(0x12, 0x34, 0x56), annotation.textColor)
      } finally { overlay.dispose() }
    }
  }

  @Test
  fun physicalRectangleAndAlignmentStayDirectionIndependent() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        val bounds = TextAnnotationBounds(40.0, 30.0, 180.0, 70.0)
        val cases = listOf(
          TextDirection.LTR to TextAlignment.START,
          TextDirection.RTL to TextAlignment.START,
          TextDirection.LTR to TextAlignment.END,
          TextDirection.RTL to TextAlignment.END,
          TextDirection.RTL to TextAlignment.CENTER,
        )
        cases.forEach { (direction, alignment) ->
          harness.insertText(
            bounds,
            "short",
            TextAnnotationOptions(untracked = null, font = null,
              fontSize = null,
              color = null,
              direction = direction,
              maxLines = null,
              alignment = alignment,
              verticalAnchor = null,
            ),
          )
        }
        harness.insertText(
          bounds,
          "short",
          TextAnnotationOptions(untracked = null, font = null,
            fontSize = null,
            color = null,
            direction = TextDirection.RTL,
            maxLines = null,
            alignment = TextAlignment.START,
            verticalAnchor = TextVerticalAnchor.BOTTOM,
          ),
        )
        val annotations = checkNotNull(harness.surface.textPresentationSnapshot()).annotations
        assertEquals(6, annotations.size)
        assertTrue(annotations.all { it.flowBounds == PageRect(40.0, 30.0, 220.0, 100.0) })
        val flowWidth = 180.0
        fun layout(annotation: TextAnnotation) = TextLayoutSpec.createLayout(annotation)
        val leftStart = layout(annotations[0]).getLineLeft(0)
        val rightStart = layout(annotations[1]).getLineRight(0)
        val rightEnd = layout(annotations[2]).getLineRight(0)
        val leftEnd = layout(annotations[3]).getLineLeft(0)
        val center = layout(annotations[4])
        assertEquals(0f, leftStart, 1f)
        assertEquals(flowWidth.toFloat(), rightStart, 1f)
        assertEquals(flowWidth.toFloat(), rightEnd, 1f)
        assertEquals(0f, leftEnd, 1f)
        assertEquals(flowWidth / 2.0, (center.getLineLeft(0) + center.getLineRight(0)) / 2.0, 1.0)

        val export = PdfExportTextResolver.resolve(
          PdfExportSnapshot(
            sourcePath = "unused-source.pdf",
            outputPath = "unused-output.pdf",
            pages = listOf(
              PdfPageExportSnapshot(
                pageIndex = 0,
                dimensions = PdfPageDimensions(300.0, 300.0),
                strokes = emptyList(),
                textAnnotations = annotations,
              ),
            ),
            generation = 1L,
          ),
        )
        val exportedLines = export.runs.groupBy { it.lineId }.values.toList()
        assertEquals("Every one-line preview remains one exported line", 6, exportedLines.size)
        assertEquals(listOf(0, 2, 2, 0, 1, 2), exportedLines.map { it.first().textAlignment })

        val before = annotations.toList()
        val error = assertThrows(PdfSessionException::class.java) {
          harness.insertText(
            TextAnnotationBounds(280.0, 20.0, 40.0, 40.0),
            "outside page",
            null,
          )
        }
        assertEquals("invalid_text_bounds", error.code)
        assertEquals(before, harness.surface.textPresentationSnapshot()?.annotations)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun maxLinesDoesNotForceLinesBeyondThePhysicalBoxHeight() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        val oneLineLayout = TextLayoutSpec.createLayout(
          text = "one",
          fontSize = defaultTextFontSize,
          textColor = android.graphics.Color.BLACK,
          layoutWidth = 100.0,
          baseDirectionRtl = false,
        )
        val box = TextAnnotationBounds(
          40.0,
          30.0,
          100.0,
          oneLineLayout.height + 0.01,
        )
        harness.insertText(
          box,
          "one\ntwo",
          TextAnnotationOptions(untracked = null, font = null,
            fontSize = null,
            color = null,
            direction = TextDirection.LTR,
            maxLines = 2.0,
            alignment = TextAlignment.START,
            verticalAnchor = null,
          ),
        )
        val annotation = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        val layout = TextLayoutSpec.createLayout(annotation)
        val selection = TextLayoutSpec.selectVisibleLines(
          layout,
          checkNotNull(annotation.flowBounds),
          annotation.maxLines,
          annotation.verticalAnchor,
        )
        assertEquals(2, layout.lineCount)
        assertEquals(1, selection.lineCount)
        assertTrue(annotation.bounds.bottom <= annotation.flowBounds!!.bottom)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun autoSizedManualPlacementAppliesMaxLines() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(
          1L,
          TextModeOptions(font = null,
            direction = TextDirection.LTR,
            width = null,
            height = null,
            maxLines = 2.0,
            alignment = TextAlignment.START,
            verticalAnchor = TextVerticalAnchor.TOP,
            x = null, y = null, zoom = null,
          ),
        )
        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        val tap = presentation.transform.map(PagePoint(40.0, 50.0))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 1_200L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 1_210L))

        val editor = editorView(overlay)
        editor.setText("first\nsecond")
        editor.setSelection(editor.length())
        editor.text.insert(editor.selectionEnd, "\nthird")
        assertEquals("first\nsecond", editor.text.toString())
        assertEquals(2, editor.layout.lineCount)
        overlay.finishForLifecycle()
        val annotation = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertTrue(annotation.flowBounds != null)
        assertTrue(annotation.autoWidth)
        assertTrue(annotation.autoHeight)
        assertEquals(2, annotation.maxLines)
        assertEquals(2, TextLayoutSpec.createLayout(annotation).lineCount)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun programmaticTextWrapsAndClipsToPagePointLimits() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        harness.insertText(
          TextAnnotationBounds(50.0, 40.0, 42.0, 42.0),
          "one two three four five six seven eight nine ten",
          TextAnnotationOptions(untracked = null, font = null,
            fontSize = null,
            color = null,
            direction = TextDirection.LTR,
            maxLines = null,
            alignment = TextAlignment.START,
            verticalAnchor = null,
          ),
        )
        harness.insertText(
          TextAnnotationBounds(208.0, 40.0, 42.0, 42.0),
          "RTL text wraps near the left edge",
          TextAnnotationOptions(untracked = null, font = null,
            fontSize = null,
            color = null,
            direction = TextDirection.RTL,
            maxLines = null,
            alignment = TextAlignment.START,
            verticalAnchor = null,
          ),
        )
        harness.surface.layoutDirection = View.LAYOUT_DIRECTION_RTL
        harness.insertText(
          TextAnnotationBounds(208.0, 100.0, 42.0, 50.0),
          "Auto follows app layout",
          TextAnnotationOptions(untracked = null, font = null,
            fontSize = null,
            color = null,
            direction = TextDirection.AUTO,
            maxLines = null,
            alignment = TextAlignment.START,
            verticalAnchor = null,
          ),
        )

        val annotation = checkNotNull(harness.surface.textPresentationSnapshot())
          .annotations.first()
        val annotations = checkNotNull(harness.surface.textPresentationSnapshot()).annotations
        val rtlAnnotation = annotations[1]
        val autoAnnotation = annotations.last()
        assertEquals(PageRect(50.0, 40.0, 92.0, 82.0), annotation.flowBounds)
        assertTrue(annotation.bounds.left >= 50.0)
        assertTrue(annotation.bounds.right <= 92.0)
        assertTrue(annotation.bounds.top >= 40.0)
        assertTrue(annotation.bounds.bottom <= 82.0)
        val layout = TextLayoutSpec.createLayout(annotation)
        assertTrue("The page-point width should wrap the text", layout.lineCount > 1)
        assertTrue("The layout should extend below its clip region", layout.height > 42)
        assertEquals(PageRect(208.0, 40.0, 250.0, 82.0), rtlAnnotation.flowBounds)
        assertTrue(rtlAnnotation.directionRtl)
        val rtlLayout = TextLayoutSpec.createLayout(rtlAnnotation)
        assertTrue(rtlLayout.lineCount > 1)
        assertTrue(autoAnnotation.directionRtl)

        val bitmap = Bitmap.createBitmap(300, 300, Bitmap.Config.ARGB_8888)
        try {
          TextRenderLayer.from(listOf(annotation)).draw(android.graphics.Canvas(bitmap))
          assertTrue((0 until 300).any { y ->
            (0 until 300).any { x -> android.graphics.Color.alpha(bitmap.getPixel(x, y)) > 0 }
          })
          assertEquals(0, android.graphics.Color.alpha(bitmap.getPixel(92, 50)))
          assertEquals(0, android.graphics.Color.alpha(bitmap.getPixel(60, 82)))
        } finally {
          bitmap.recycle()
        }

        val snapshot = PdfExportSnapshot(
          sourcePath = "unused-source.pdf",
          outputPath = "unused-output.pdf",
          pages = listOf(
            PdfPageExportSnapshot(
              pageIndex = 0,
              dimensions = PdfPageDimensions(300.0, 300.0),
              strokes = emptyList(),
              textAnnotations = listOf(annotation, rtlAnnotation),
            ),
          ),
          generation = 1L,
        )
        val exported = PdfExportTextResolver.resolve(snapshot)
        assertTrue(exported.runs.isNotEmpty())
        assertTrue(exported.runs.all { it.baselineFromTop < 82.0f })
        assertTrue(
          exported.runs.map { it.lineId }.distinct().size < layout.lineCount + rtlLayout.lineCount,
        )
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun programmaticBottomAnchorKeepsFirstLinesAndExportsAtTheFixedBottom() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        harness.insertText(
          TextAnnotationBounds(20.0, 180.0, 260.0, 80.0),
          "one\ntwo\nthree\nfour",
          TextAnnotationOptions(untracked = null, font = null,
            fontSize = null,
            color = null,
            direction = TextDirection.LTR,
            alignment = TextAlignment.START,
            maxLines = 2.0,
            verticalAnchor = TextVerticalAnchor.BOTTOM,
          ),
        )
        harness.insertText(
          TextAnnotationBounds(20.0, 230.0, 260.0, 30.0),
          "one\ntwo\nthree",
          TextAnnotationOptions(untracked = null, font = null,
            fontSize = null,
            color = null,
            direction = TextDirection.LTR,
            alignment = TextAlignment.START,
            maxLines = 3.0,
            verticalAnchor = TextVerticalAnchor.BOTTOM,
          ),
        )

        val annotations = checkNotNull(harness.surface.textPresentationSnapshot()).annotations
        val lineLimited = annotations[0]
        val regionLimited = annotations[1]
        val lineLimitedBounds = checkNotNull(lineLimited.flowBounds)
        val regionLimitedBounds = checkNotNull(regionLimited.flowBounds)
        val lineLimitedSelection = TextLayoutSpec.selectVisibleLines(
          TextLayoutSpec.createLayout(lineLimited),
          lineLimitedBounds,
          lineLimited.maxLines,
          lineLimited.verticalAnchor,
        )
        val regionLimitedSelection = TextLayoutSpec.selectVisibleLines(
          TextLayoutSpec.createLayout(regionLimited),
          regionLimitedBounds,
          regionLimited.maxLines,
          regionLimited.verticalAnchor,
        )
        assertEquals(2, lineLimitedSelection.lineCount)
        assertEquals(1, regionLimitedSelection.lineCount)
        assertTrue(lineLimited.bounds.top > lineLimitedBounds.top)
        assertEquals(lineLimitedBounds.bottom, lineLimited.bounds.bottom, 0.0)
        assertTrue(regionLimited.bounds.top >= regionLimitedBounds.top)
        assertEquals(regionLimitedBounds.bottom, regionLimited.bounds.bottom, 0.0)

        val exported = PdfExportTextResolver.resolve(
          PdfExportSnapshot(
            sourcePath = "unused-source.pdf",
            outputPath = "unused-output.pdf",
            pages = listOf(
              PdfPageExportSnapshot(
                pageIndex = 0,
                dimensions = PdfPageDimensions(300.0, 300.0),
                strokes = emptyList(),
                textAnnotations = annotations,
              ),
            ),
            generation = 1L,
          ),
        )
        assertEquals(listOf("one", "two", "one"), exported.runs.map { it.text })
        assertTrue(exported.runs.all { it.baselineFromTop in 180.0f..260.0f })
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun logicalGrowthKeepsAcceptedEdgesThroughNewlinesAndDeletion() {
    val cases = listOf(
      Triple(false, TextAlignment.START, TextVerticalAnchor.TOP),
      Triple(true, TextAlignment.START, TextVerticalAnchor.TOP),
      Triple(false, TextAlignment.CENTER, TextVerticalAnchor.TOP),
      Triple(false, TextAlignment.START, TextVerticalAnchor.BOTTOM),
    )
    for ((rtl, alignment, vertical) in cases) harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        overlay.armPlacement(presentation.generation, TextModeOptions(font = null,
          direction = if (rtl) TextDirection.RTL else TextDirection.LTR,
          width = null, height = null, maxLines = null, alignment = alignment,
          verticalAnchor = vertical, x = null, y = null, zoom = null))
        val tap = presentation.transform.map(PagePoint(150.0, 140.0))
        dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 1_200L)
        dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 1_210L)
        val editor = editorView(overlay)
        for (value in listOf("A", "A longer line", "First\nSecond\nThird", "A", "")) {
          editor.setText(value)
          val bounds = editorPageBounds(editor)
          val right = (alignment == TextAlignment.START && rtl) || (alignment == TextAlignment.END && !rtl)
          val edge = when {
            alignment == TextAlignment.CENTER -> (bounds.left + bounds.right) / 2.0
            right -> bounds.right
            else -> bounds.left
          }
          assertEquals(150.0, edge, 1.5)
          assertEquals(140.0, if (vertical == TextVerticalAnchor.BOTTOM) bounds.bottom else bounds.top, 1.5)
        }
      } finally { overlay.dispose() }
    }
  }

  @Test
  fun independentDimensionsRetainAdmissionAndSavedAxisIntent() {
    for ((width, height) in listOf(70.0 to null, null to 45.0, 70.0 to 45.0, null to null)) harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        overlay.armPlacement(presentation.generation, TextModeOptions(font = null,
          direction = TextDirection.LTR, width = width, height = height, maxLines = 5.0,
          alignment = TextAlignment.START, verticalAnchor = TextVerticalAnchor.TOP,
          x = null, y = null, zoom = null))
        val tap = presentation.transform.map(PagePoint(100.0, 100.0))
        dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 1_220L)
        dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 1_230L)
        val editor = editorView(overlay)
        editor.setText("First")
        if (height != null) {
          editor.append("\nSecond\nThird\nFourth")
          assertEquals("First", editor.text.toString())
        }
        if (width != null) assertEquals(width, editorPageBounds(editor).right - editorPageBounds(editor).left, 1.5)
        overlay.finishForLifecycle()
        val saved = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertEquals(width == null, saved.autoWidth)
        assertEquals(height == null, saved.autoHeight)
        val current = checkNotNull(harness.surface.textPresentationSnapshot())
        val reopen = current.transform.map(PagePoint((saved.bounds.left + saved.bounds.right) / 2.0,
          (saved.bounds.top + saved.bounds.bottom) / 2.0))
        dispatch(overlay, MotionEvent.ACTION_DOWN, reopen.x.toFloat(), reopen.y.toFloat(), 1_240L)
        dispatch(overlay, MotionEvent.ACTION_UP, reopen.x.toFloat(), reopen.y.toFloat(), 1_250L)
        assertEquals("First", editorView(overlay).text.toString())
        assertEquals(100.0, editorPageBounds(editorView(overlay)).top, 1.5)
      } finally { overlay.dispose() }
    }
  }

  @Test
  fun manualFlowOptionsConstrainLiveEditorAndSurviveCommitAndReopen() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        val options = TextModeOptions(font = null,
          direction = TextDirection.LTR,
          width = 110.0,
          height = 80.0,
          maxLines = 2.0,
          alignment = TextAlignment.START,
          verticalAnchor = TextVerticalAnchor.BOTTOM,
          x = null, y = null, zoom = null,
        )
        overlay.armPlacement(1L, options)
        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        val invalidTap = presentation.transform.map(PagePoint(200.0, 180.0))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, invalidTap.x.toFloat(), invalidTap.y.toFloat(), 1_300L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, invalidTap.x.toFloat(), invalidTap.y.toFloat(), 1_310L))
        assertTrue(overlay.hasPendingPlacement())
        assertEquals(0, editorCount(overlay))

        val tap = presentation.transform.map(PagePoint(40.0, 100.0))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 1_320L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 1_330L))
        assertFalse(overlay.hasPendingPlacement())
        val editor = editorView(overlay)
        editor.setText("one\ntwo")
        val liveBounds = editorPageBounds(editor)
        assertEquals(40.0, liveBounds.left, 1.0)
        assertEquals(150.0, liveBounds.right, 1.0)
        assertTrue(liveBounds.top > 100.0)
        assertEquals(180.0, liveBounds.bottom, 1.0)

        overlay.setTextDirection(TextDirection.RTL)
        assertEquals(TextView.TEXT_DIRECTION_RTL, editor.textDirection)
        assertEquals(liveBounds, editorPageBounds(editor))
        overlay.finishForLifecycle()

        val saved = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertEquals(PageRect(40.0, 100.0, 150.0, 180.0), saved.flowBounds)
        assertEquals(2, saved.maxLines)
        assertEquals(TextVerticalAnchor.BOTTOM, saved.verticalAnchor)
        assertEquals(180.0, saved.bounds.bottom, 0.0)

        val savedPresentation = checkNotNull(harness.surface.textPresentationSnapshot())
        val reopenPoint = savedPresentation.transform.map(
          PagePoint(
            (saved.bounds.left + saved.bounds.right) / 2.0,
            (saved.bounds.top + saved.bounds.bottom) / 2.0,
          ),
        )
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, reopenPoint.x.toFloat(), reopenPoint.y.toFloat(), 1_340L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, reopenPoint.x.toFloat(), reopenPoint.y.toFloat(), 1_350L))
        assertEquals("one\ntwo", editorView(overlay).text.toString())
        overlay.increaseTextSize()
        overlay.finishForLifecycle()

        val reopened = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertEquals(2, reopened.maxLines)
        assertEquals(TextVerticalAnchor.BOTTOM, reopened.verticalAnchor)
        assertEquals(saved.flowBounds, reopened.flowBounds)
        assertEquals(180.0, reopened.bounds.bottom, 0.0)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun constrainedEditorRejectsOverflowAndRestoresTextAndCaret() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        val fourCharacterWidth = kotlin.math.ceil(
          TextLayoutSpec.createPaint(defaultTextFontSize).measureText("MMMM").toDouble(),
        )
        val flowBounds = PageRect(20.0, 100.0, 20.0 + fourCharacterWidth, 250.0)
        val options = TextModeOptions(font = null,
          direction = TextDirection.LTR,
          width = flowBounds.right - flowBounds.left,
          height = flowBounds.bottom - flowBounds.top,
          maxLines = 2.0,
          alignment = TextAlignment.START,
          verticalAnchor = TextVerticalAnchor.BOTTOM,
          x = null, y = null, zoom = null,
        )
        overlay.armPlacement(1L, options)
        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        val tap = presentation.transform.map(PagePoint(20.0, 100.0))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 1_360L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 1_370L))

        val editor = editorView(overlay)
        val fullText = "MMMM\nMMMM"
        assertTrue(
          TextLayoutSpec.fitsFlow(
            text = fullText,
            fontSize = defaultTextFontSize,
            textColor = android.graphics.Color.BLACK,
            flowBounds = flowBounds,
            maxLines = 2,
            baseDirectionRtl = false,
          ),
        )
        editor.setText(fullText)
        editor.setSelection(fullText.length)

        editor.text.insert(editor.selectionEnd, "M")
        assertEquals(fullText, editor.text.toString())
        assertEquals(fullText.length, editor.selectionStart)
        assertEquals(fullText.length, editor.selectionEnd)

        editor.text.insert(editor.selectionEnd, "\n")
        assertEquals(fullText, editor.text.toString())
        assertEquals(fullText.length, editor.selectionStart)
        assertEquals(fullText.length, editor.selectionEnd)

        val clipboard = checkNotNull(
          InstrumentationRegistry.getInstrumentation().targetContext
            .getSystemService(ClipboardManager::class.java),
        )
        clipboard.setPrimaryClip(ClipData.newPlainText("overflow", "M"))
        assertTrue(editor.onTextContextMenuItem(android.R.id.paste))
        assertEquals(fullText, editor.text.toString())
        assertEquals(fullText.length, editor.selectionStart)
        assertEquals(fullText.length, editor.selectionEnd)

        editor.setSelection(5, fullText.length)
        editor.text.replace(5, fullText.length, "MMMMM")
        assertEquals("MMMM\n", editor.text.toString())
        assertEquals(5, editor.selectionStart)
        assertEquals(5, editor.selectionEnd)
        editor.text.insert(editor.selectionEnd, "MMMM")
        assertEquals(fullText, editor.text.toString())

        editor.setSelection(fullText.length)
        editor.text.delete(fullText.length - 1, fullText.length)
        assertEquals("MMMM\nMMM", editor.text.toString())
        assertEquals(fullText.length - 1, editor.selectionEnd)
        editor.text.insert(editor.selectionEnd, "M")
        assertEquals(fullText, editor.text.toString())
        assertEquals(fullText.length, editor.selectionEnd)

        val inputConnection = checkNotNull(editor.onCreateInputConnection(EditorInfo()))
        val composingM = SpannableString("M").apply {
          setSpan(UnderlineSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val composingMM = SpannableString("MM").apply {
          setSpan(UnderlineSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }

        editor.text.delete(fullText.length - 1, fullText.length)
        assertEquals("MMMM\nMMM", editor.text.toString())
        editor.setSelection(editor.text.length)
        assertTrue(inputConnection.setComposingText(composingM, 1))
        assertEquals(fullText, editor.text.toString())
        assertEquals(fullText.length, editor.selectionStart)
        assertEquals(fullText.length, editor.selectionEnd)

        // Extending the active composition now overflows. Preserve its old range.
        assertTrue(inputConnection.setComposingText(composingMM, 1))
        assertEquals(fullText, editor.text.toString())
        assertEquals(fullText.length, editor.selectionStart)
        assertEquals(fullText.length, editor.selectionEnd)
        assertEquals(fullText.length - 1, BaseInputConnection.getComposingSpanStart(editor.text))
        assertEquals(fullText.length, BaseInputConnection.getComposingSpanEnd(editor.text))
        val underline = editor.text.getSpans(0, editor.text.length, UnderlineSpan::class.java)
        assertEquals(1, underline.size)
        assertEquals(fullText.length - 1, editor.text.getSpanStart(underline.single()))
        assertEquals(fullText.length, editor.text.getSpanEnd(underline.single()))
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun constrainedEditorKeepsTextAcrossReflowAndAllowsEditingBackIntoSpace() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        val fourCharacterWidth = kotlin.math.ceil(
          TextLayoutSpec.createPaint(defaultTextFontSize).measureText("MMMM").toDouble(),
        )
        val flowBounds = PageRect(20.0, 100.0, 20.0 + fourCharacterWidth, 250.0)
        overlay.armPlacement(
          1L,
          TextModeOptions(font = null,
            direction = TextDirection.LTR,
            width = flowBounds.right - flowBounds.left,
            height = flowBounds.bottom - flowBounds.top,
            maxLines = 2.0,
            alignment = TextAlignment.START,
            verticalAnchor = TextVerticalAnchor.BOTTOM,
            x = null, y = null, zoom = null,
          ),
        )
        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        val tap = presentation.transform.map(PagePoint(20.0, 100.0))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 1_380L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 1_390L))

        val editor = editorView(overlay)
        val fullText = "MMMM\nMMMM"
        editor.setText(fullText)
        val inputConnection = checkNotNull(editor.onCreateInputConnection(EditorInfo()))
        editor.setSelection(5, fullText.length)
        val originalComposingText = SpannableString("MMMM").apply {
          setSpan(UnderlineSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        assertTrue(inputConnection.setComposingText(originalComposingText, 1))
        overlay.setTextDirection(TextDirection.RTL)
        overlay.increaseTextSize()
        assertEquals(fullText, editor.text.toString())
        assertFalse(
          TextLayoutSpec.fitsFlow(
            text = fullText,
            fontSize = defaultTextFontSize + 1.0,
            textColor = android.graphics.Color.BLACK,
            flowBounds = flowBounds,
            maxLines = 2,
            baseDirectionRtl = true,
          ),
        )

        val shorterComposingText = SpannableString("MMM").apply {
          setSpan(UnderlineSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        assertTrue(inputConnection.setComposingText(shorterComposingText, 1))
        assertEquals("MMMM\nMMM", editor.text.toString())
        assertFalse(
          TextLayoutSpec.fitsFlow(
            text = editor.text.toString(),
            fontSize = defaultTextFontSize + 1.0,
            textColor = android.graphics.Color.BLACK,
            flowBounds = flowBounds,
            maxLines = 2,
            baseDirectionRtl = true,
          ),
        )
        assertEquals(5, BaseInputConnection.getComposingSpanStart(editor.text))
        assertEquals(editor.text.length, BaseInputConnection.getComposingSpanEnd(editor.text))
        assertTrue(inputConnection.finishComposingText())

        editor.text.delete(3, 4)
        assertEquals("MMM\nMMM", editor.text.toString())
        editor.text.delete(editor.text.length - 1, editor.text.length)
        assertEquals("MMM\nMM", editor.text.toString())
        assertTrue(
          TextLayoutSpec.fitsFlow(
            text = editor.text.toString(),
            fontSize = defaultTextFontSize + 1.0,
            textColor = android.graphics.Color.BLACK,
            flowBounds = flowBounds,
            maxLines = 2,
            baseDirectionRtl = true,
          ),
        )

        overlay.decreaseTextSize()
        editor.setSelection(editor.text.length)
        editor.text.insert(editor.selectionEnd, "MM")
        assertEquals("MMM\nMMMM", editor.text.toString())
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun placementWaitsForTapEndAndLaterOutsideTapFinishesTheDraft() {
    lateinit var overlay: TextInteractionOverlay
    val modes = mutableListOf<InteractionMode>()
    harness.runOnMain {
      harness.setDocument(
        harness.info,
        zoom = 1.0,
        focus = PagePoint(150.0, 150.0),
        fitToPage = false,
      )
      overlay = harness.createOverlay()
      overlay.onInteractionModeChanged = { modes += overlay.interactionMode() }
      overlay.armPlacement(1L)

      assertEquals(InteractionMode.TEXTADD, overlay.interactionMode())
      assertTrue(overlay.hasPendingPlacement())
      val outsidePage = checkNotNull(harness.surface.textPresentationSnapshot())
        .transform.map(PagePoint(-1.0, -1.0))
      assertFalse(dispatchTouch(overlay, MotionEvent.ACTION_DOWN, outsidePage.x.toFloat(), outsidePage.y.toFloat(), 990L, 990L))
      dispatchTouch(overlay, MotionEvent.ACTION_UP, outsidePage.x.toFloat(), outsidePage.y.toFloat(), 990L, 995L)
      assertTrue(overlay.hasPendingPlacement())

      assertTrue(dispatchTouch(overlay, MotionEvent.ACTION_DOWN, 150.0f, 150.0f, 1_000L, 1_000L))
      assertEquals(InteractionMode.TEXTADD, overlay.interactionMode())
      assertEquals(0, editorCount(overlay))
      assertTrue(dispatchTouch(overlay, MotionEvent.ACTION_MOVE, 151.0f, 151.0f, 1_000L, 1_010L))
      assertEquals(0, editorCount(overlay))
      assertTrue(dispatchTouch(overlay, MotionEvent.ACTION_UP, 150.0f, 150.0f, 1_000L, 1_020L))
      assertFalse(overlay.hasPendingPlacement())
      assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
      assertNotNull(overlay.editingAnnotationId())
      assertEquals(1, editorCount(overlay))
      assertTrue(
        harness.surface.textPresentationSnapshot()?.annotations.orEmpty().isEmpty(),
      )
    }
    harness.waitForViewportAnimationToFinish()
    harness.runOnMain {
      assertEquals(1.0, harness.surface.currentViewportState().zoom, 0.02)
      harness.surface.setKeyboardOcclusion(80.0)
      overlay.syncTransform()
      assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
      assertNotNull(overlay.editingAnnotationId())
      assertTrue(modes.contains(InteractionMode.TEXTADD))
      assertTrue(modes.contains(InteractionMode.TEXTEDIT))

      assertTrue(dispatchTouch(overlay, MotionEvent.ACTION_DOWN, 290.0f, 290.0f, 1_040L, 1_040L))
      assertTrue(dispatchTouch(overlay, MotionEvent.ACTION_UP, 290.0f, 290.0f, 1_040L, 1_060L))
      assertEquals(InteractionMode.VIEW, overlay.interactionMode())
      assertEquals(0, editorCount(overlay))
      assertTrue(
        harness.surface.textPresentationSnapshot()?.annotations.orEmpty().isEmpty(),
      )
      overlay.dispose()
    }
  }

  @Test
  fun placementViewportIsDeferredAndIndependentOfDoubleTap() {
    harness.runOnMain {
      val overlay = harness.createOverlay()
      harness.surface.setDoubleTapConfiguration(
        DoubleTapOptions(zoom = 2.5, enterEditMode = false),
      )
      harness.setDocument(
        harness.info,
        zoom = 1.0,
        focus = PagePoint(150.0, 150.0),
        fitToPage = false,
      )
      overlay.syncContent()
      overlay.armPlacement(1L)
      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150.0f, 150.0f, 1_100L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150.0f, 150.0f, 1_120L))
    }
    harness.waitForViewportAnimationToFinish()
    harness.runOnMain {
      assertEquals(1.0, harness.surface.currentViewportState().zoom, 0.02)
      val overlay = checkNotNull(harness.overlay)
      overlay.finishForLifecycle()
      harness.surface.setDoubleTapConfiguration(
        DoubleTapOptions(zoom = 2.0, enterEditMode = false),
      )
      harness.setDocument(
        harness.info,
        zoom = 3.0,
        focus = PagePoint(150.0, 150.0),
        fitToPage = false,
      )
      overlay.syncContent()
      overlay.armPlacement(1L, TextModeOptions(font = null,
        direction = null, width = null, height = null, maxLines = null,
        alignment = null, verticalAnchor = null, x = null, y = null, zoom = 2.5,
      ))
      assertEquals(3.0, harness.surface.currentViewportState().zoom, 0.02)
      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150.0f, 150.0f, 1_200L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150.0f, 150.0f, 1_220L))
    }
    harness.waitForViewportAnimationToFinish()
    harness.runOnMain {
      assertEquals(2.5, harness.surface.currentViewportState().zoom, 0.02)
      harness.overlay?.dispose()
    }
  }

  @Test
  fun emptyTextModeOptionsFitOnlyAfterPlacementTap() {
    var fittedZoom = 0.0
    harness.runOnMain {
      harness.setDocument(harness.info)
      fittedZoom = harness.surface.currentViewportState().zoom
      harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      overlay.armPlacement(1L, TextModeOptions(font = null,
        direction = null, width = null, height = null, maxLines = null,
        alignment = null, verticalAnchor = null, x = null, y = null, zoom = null,
      ))
      assertEquals(3.0, harness.surface.currentViewportState().zoom, 0.02)
      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150.0f, 150.0f, 1_100L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150.0f, 150.0f, 1_120L))
    }
    harness.waitForViewportAnimationToFinish()
    harness.runOnMain {
      assertEquals(fittedZoom, harness.surface.currentViewportState().zoom, 0.02)
      harness.overlay?.dispose()
    }
  }

  @Test
  fun placementNearRuleSnapsEditorBottomAboveIt() {
    val candidate = PdfiumHorizontalSnapCandidate(60.0, 240.0, 180.0)
    lateinit var overlay: TextInteractionOverlay
    var expectedBottom = 0.0
    harness.runOnMain {
      harness.setDocument(harness.info)
      harness.surface.installSnapCandidateMeasurement(
        harness.info.generation, 0, harness.surface.currentPageSwitchId, listOf(candidate),
      )
      overlay = harness.createOverlay()
      overlay.armPlacement(1L)
      val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
      val tap = presentation.transform.map(PagePoint(150.0, 176.0))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 1_050L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 1_060L))
      expectedBottom = candidate.y
    }
    try {
      harness.waitForViewportAnimationToFinish()
      harness.runOnMain {
        val editor = editorView(overlay)
        val transform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val displayedBottom = transform.inverse()
          .map(PagePoint(editor.left.toDouble(), editor.bottom.toDouble())).y
        assertEquals(expectedBottom, displayedBottom, 1.0)
      }
    } finally {
      harness.runOnMain { overlay.dispose() }
    }
  }

  @Test
  fun explicitTopOverridesRuleSnapDefault() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      harness.surface.installSnapCandidateMeasurement(harness.info.generation, 0,
        harness.surface.currentPageSwitchId, listOf(PdfiumHorizontalSnapCandidate(60.0, 240.0, 180.0)))
      val overlay = harness.createOverlay()
      try {
        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        overlay.armPlacement(presentation.generation, TextModeOptions(font = null,
          direction = TextDirection.LTR, width = null, height = null, maxLines = null,
          alignment = TextAlignment.START, verticalAnchor = TextVerticalAnchor.TOP,
          x = null, y = null, zoom = null))
        val tap = presentation.transform.map(PagePoint(150.0, 176.0))
        dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 1_070L)
        dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 1_080L)
        val editor = editorView(overlay)
        for (value in listOf("First", "First\nSecond", "First")) {
          editor.setText(value)
          assertEquals(value, editor.text.toString())
          assertEquals(180.0, editorPageBounds(editor).top, 1.5)
        }
      } finally { overlay.dispose() }
    }
  }

  @Test
  fun replacementDoesNotReusePreviousPageSnapCandidates() = runBlocking {
    val replacement = java.io.File.createTempFile("snap-replacement-", ".pdf").apply {
      writeText("replacement")
    }
    try {
      harness.runOnMain {
        val candidate = PdfiumHorizontalSnapCandidate(20.0, 280.0, 140.0)
        harness.setDocument(harness.info)
        harness.surface.installSnapCandidateMeasurement(
          harness.info.generation, 0, harness.surface.currentPageSwitchId, listOf(candidate),
        )
        assertEquals(listOf(candidate), harness.surface.textPresentationSnapshot()?.snapCandidates)
      }
      openCandidate(replacement)
      harness.runOnMain {
        assertTrue(harness.surface.textPresentationSnapshot()?.snapCandidates.orEmpty().isEmpty())
      }
    } finally {
      replacement.delete()
    }
  }

  @Test
  fun snapMeasurementsAreRequestedForOnePageAndClearedOnPageChange() = runBlocking {
    val source = java.io.File.createTempFile("lazy-snap-", ".pdf").apply { writeText("candidate") }
    try {
      openCandidate(source)
      val resource = harness.openedResources.last()
      assertTrue(resource.snapCandidateRequests.isEmpty())

      val completed = CountDownLatch(1)
      val result = java.util.concurrent.atomic.AtomicReference<
        Result<List<PdfiumHorizontalSnapCandidate>>,
      >()
      harness.coordinator.horizontalSnapCandidates(harness.coordinator.generation, 1) {
        result.set(it)
        completed.countDown()
      }
      assertTrue("PDF worker did not finish the page snap scan", completed.await(5L, TimeUnit.SECONDS))
      assertTrue(result.get().isSuccess)
      assertEquals(listOf(1), resource.snapCandidateRequests.toList())

      val candidate = PdfiumHorizontalSnapCandidate(20.0, 280.0, 140.0)
      harness.runOnMain {
        val originalPageSwitchId = harness.surface.currentPageSwitchId
        harness.surface.installSnapCandidateMeasurement(
          harness.coordinator.generation, 0, originalPageSwitchId, listOf(candidate),
        )
        assertEquals(listOf(candidate), harness.surface.textPresentationSnapshot()?.snapCandidates)
        harness.surface.switchPage(1)
        assertTrue(harness.surface.textPresentationSnapshot()?.snapCandidates.orEmpty().isEmpty())
        harness.surface.switchPage(0)
        assertTrue(harness.surface.textPresentationSnapshot()?.snapCandidates.orEmpty().isEmpty())
        harness.surface.installSnapCandidateMeasurement(
          harness.coordinator.generation, 0, originalPageSwitchId, listOf(candidate),
        )
        assertTrue(harness.surface.textPresentationSnapshot()?.snapCandidates.orEmpty().isEmpty())
      }
    } finally {
      source.delete()
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
        id = 1L,
        text = "Hello",
        bounds = PageRect(80.0, 80.0, 120.0, 98.0),
        fontSize = 16.0,
        verticalAnchor = TextVerticalAnchor.BOTTOM,
      )
      appendTestText(original)
      overlay.syncContent()
      val point = checkNotNull(harness.surface.textPresentationSnapshot())
        .transform.map(original.position)

      try {
        dispatch(overlay, MotionEvent.ACTION_DOWN, point.x.toFloat(), point.y.toFloat(), 3_000L)
        dispatch(overlay, MotionEvent.ACTION_UP, point.x.toFloat(), point.y.toFloat(), 3_020L)

        assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
        val editor = overlay.getChildAt(0) as EditText
        editor.setSelection(1, 3)
        val result = overlay.increaseTextSize()

        assertEquals(17.0, result, 0.0)
        assertEquals("Hello", editor.text.toString())
        assertEquals(1, editor.selectionStart)
        assertEquals(3, editor.selectionEnd)
        assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())

        editor.setText("Updated")
        overlay.finishForLifecycle()
        val updated = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertEquals("Updated", updated.text)
        assertEquals(17.0, updated.fontSize, 0.0)
        assertEquals(original.bounds.top, updated.bounds.top, 0.0)

        harness.undo()
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
        id = 1L,
        text = "Hello",
        bounds = PageRect(80.0, 80.0, 140.0, 100.0),
        fontSize = 16.0,
      )
      appendTestText(annotation)
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
        assertEquals(InteractionMode.VIEW, overlay.interactionMode())
        assertEquals(null, overlay.editingAnnotationId())
        assertEquals(revisionBeforeHold, harness.activeHistoryRevision())
        assertEquals(16.0, checkNotNull(harness.surface.textPresentationSnapshot())
          .annotations.single().fontSize, 0.0)
        assertEquals(17.0, overlay.increaseTextSize(), 0.0)
        assertEquals(InteractionMode.VIEW, overlay.interactionMode())
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
        id = 1L,
        text = "Hello",
        bounds = PageRect(80.0, 80.0, 140.0, 100.0),
        fontSize = 16.0,
      )
      original = created
      appendTestText(original)
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
        assertEquals(InteractionMode.VIEW, overlay.interactionMode())
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
        assertEquals(InteractionMode.VIEW, overlay.interactionMode())
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
      val annotationId = if (isRtl) 2L else 1L
      harness.runOnMain {
        overlay = harness.createOverlay()
        val annotation = TextAnnotation(
          id = annotationId,
          text = "Selected",
          bounds = PageRect(80.0, 80.0, 150.0, 102.0),
          fontSize = 16.0,
          directionRtl = isRtl,
        )
        appendTestText(annotation)
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
          assertEquals(InteractionMode.VIEW, overlay.interactionMode())
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
          assertEquals(InteractionMode.VIEW, overlay.interactionMode())
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
          assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
          assertEquals(1, editorCount(overlay))
          assertEquals(revisionBeforeMove + 1L, harness.activeHistoryRevision())
        }
      } finally {
        harness.runOnMain { overlay.dispose() }
      }
    }
  }

  @Test
  fun bottomAnchoredDragPreviewStaysAlignedWithItsFlowBox() {
    lateinit var overlay: TextInteractionOverlay
    val annotation = TextAnnotation(
      id = 1L,
      text = "One line",
      bounds = PageRect(80.0, 100.0, 150.0, 120.0),
      fontSize = 16.0,
      flowBounds = PageRect(80.0, 70.0, 210.0, 120.0),
      maxLines = 2,
      verticalAnchor = TextVerticalAnchor.BOTTOM,
    )
    lateinit var originalPixels: Rect
    lateinit var presentation: TextPresentationSnapshot
    lateinit var matrix: Matrix
    lateinit var tapPoint: ViewPoint
    val dragDeltaX = 40f
    try {
      harness.runOnMain {
        overlay = harness.createOverlay()
        appendTestText(annotation)
        overlay.syncContent()
        presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        matrix = Matrix().apply {
          setValues(floatArrayOf(
            presentation.transform.a.toFloat(),
            presentation.transform.c.toFloat(),
            presentation.transform.tx.toFloat(),
            presentation.transform.b.toFloat(),
            presentation.transform.d.toFloat(),
            presentation.transform.ty.toFloat(),
            0f,
            0f,
            1f,
          ))
        }
        val baseline = Bitmap.createBitmap(overlay.width, overlay.height, Bitmap.Config.ARGB_8888)
        try {
          Canvas(baseline).apply {
            concat(matrix)
            TextRenderLayer.from(listOf(annotation)).draw(this)
          }
          originalPixels = checkNotNull(
            textPixelBounds(baseline, Rect(0, 0, baseline.width, baseline.height)),
          )
        } finally {
          baseline.recycle()
        }

        tapPoint = presentation.transform.map(PagePoint(100.0, 110.0))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tapPoint.x.toFloat(), tapPoint.y.toFloat(), 6_000L))
      }

      Thread.sleep(650L)
      harness.runOnMain {
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tapPoint.x.toFloat(), tapPoint.y.toFloat(), 6_650L))
        assertEquals(InteractionMode.VIEW, overlay.interactionMode())
        val scale = presentation.transform.uniformScale() ?: 1.0
        val horizontalPadding = textEditorPaddingPx(
          annotation.fontSize * scale,
          textEditorHorizontalPaddingRatio,
        ).toFloat()
        val verticalPadding = textEditorPaddingPx(
          annotation.fontSize * scale,
          textEditorVerticalPaddingRatio,
        ).toFloat()
        val outer = textAnnotationOuterRect(annotation.bounds, presentation.transform, horizontalPadding, verticalPadding)
        val downX = outer.centerX()
        val downY = outer.centerY()
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, downX, downY, 6_700L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_MOVE, downX + dragDeltaX, downY, 6_720L))
        assertEquals(InteractionMode.VIEW, overlay.interactionMode())

        val preview = Bitmap.createBitmap(overlay.width, overlay.height, Bitmap.Config.ARGB_8888)
        try {
          overlay.draw(Canvas(preview))
          val expected = Rect(originalPixels).apply { offset(dragDeltaX.toInt(), 0) }
          val search = Rect(expected).apply { inset(-5, -5) }
          val previewPixels = textPixelBounds(preview, search)
          assertNotNull("The drag preview text should remain at the moved flow-box location", previewPixels)
          val measured = checkNotNull(previewPixels)
          assertTrue("expected=$expected measured=$measured", kotlin.math.abs(expected.left - measured.left) <= 2)
          assertTrue("expected=$expected measured=$measured", kotlin.math.abs(expected.top - measured.top) <= 2)
          assertTrue("expected=$expected measured=$measured", kotlin.math.abs(expected.right - measured.right) <= 2)
          assertTrue("expected=$expected measured=$measured", kotlin.math.abs(expected.bottom - measured.bottom) <= 2)
        } finally {
          preview.recycle()
        }

        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, downX + dragDeltaX, downY, 6_740L))
        val committed = checkNotNull(harness.surface.textPresentationSnapshot())
          .annotations.single { it.id == annotation.id }
        val committedBitmap = Bitmap.createBitmap(overlay.width, overlay.height, Bitmap.Config.ARGB_8888)
        try {
          Canvas(committedBitmap).apply {
            concat(matrix)
            TextRenderLayer.from(listOf(committed)).draw(this)
          }
          val expected = Rect(originalPixels).apply { offset(dragDeltaX.toInt(), 0) }
          val committedPixels = textPixelBounds(committedBitmap, Rect(expected).apply { inset(-5, -5) })
          assertEquals("Release must preserve the preview's text origin", expected, committedPixels)
        } finally {
          committedBitmap.recycle()
        }
      }
    } finally {
      harness.runOnMain { overlay.dispose() }
    }
  }

  @Test
  fun editorTwoFingerPanStaysAwayUntilTypingResumesCaretFollow() {
    lateinit var overlay: TextInteractionOverlay
    var awayFocus = PagePoint(0.0, 0.0)
    harness.runOnMain {
      val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
      // Keep the viewport large enough for the zoomed line and 24 dp margins on any density.
      val viewportExtentPx = kotlin.math.ceil(300.0 * density).toInt()
      harness.setSurfaceSize(viewportExtentPx, viewportExtentPx)
      harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      overlay = harness.createOverlay()
      overlay.armPlacement(1L)
      val center = viewportExtentPx / 2f
      dispatchTouch(overlay, MotionEvent.ACTION_DOWN, center, center, 5_000L, 5_000L)
      dispatchTouch(overlay, MotionEvent.ACTION_UP, center, center, 5_000L, 5_010L)
      editorView(overlay).setText("Ada")
      editorView(overlay).setSelection(3)
    }
    try {
      harness.waitForDetachedCaretFollow()
      harness.runOnMain {
        val editor = editorView(overlay)
        val x = (editor.left + editor.right) / 2f
        val y = (editor.top + editor.bottom) / 2f
        val down = MotionEvent.obtain(5_100L, 5_100L, MotionEvent.ACTION_DOWN, x, y, 0)
        try { assertTrue(overlay.dispatchTouchEvent(down)) } finally { down.recycle() }
        dispatchEditorFingers(overlay, MotionEvent.ACTION_POINTER_DOWN or
          (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), x, y, 5_120L)
        dispatchEditorFingers(overlay, MotionEvent.ACTION_MOVE, x + overlay.width, y, 5_150L)
        dispatchEditorFingers(overlay, MotionEvent.ACTION_MOVE, x + 2f * overlay.width, y, 5_180L)
        dispatchEditorFingers(overlay, MotionEvent.ACTION_CANCEL, x + 2f * overlay.width, y, 5_200L)
        awayFocus = harness.surface.currentViewportState().focus
        assertEquals("Ada", editor.text.toString())
        assertEquals(3, editor.selectionStart)
        assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
        assertCaretIsOutsideView(editor, 3, overlay.width, overlay.height)
      }
      harness.waitForDetachedCaretFollow()
      harness.runOnMain {
        assertEquals(awayFocus, harness.surface.currentViewportState().focus)
        editorView(overlay).append("!")
      }
      harness.waitForDetachedCaretFollow()
      harness.runOnMain {
        assertCaretIsInsideView(editorView(overlay), 4, overlay.width, overlay.height)
      }
    } finally { harness.runOnMain { overlay.dispose() } }
  }

  private fun dispatchEditorFingers(
    overlay: TextInteractionOverlay, action: Int, x: Float, y: Float, time: Long,
  ) {
    val properties = Array(2) { index -> MotionEvent.PointerProperties().apply {
      id = index
      toolType = MotionEvent.TOOL_TYPE_FINGER
    } }
    val coordinates = Array(2) { index -> MotionEvent.PointerCoords().apply {
      this.x = x + index * 100f
      this.y = y
      pressure = 1f
      size = 1f
    } }
    val event = MotionEvent.obtain(5_100L, time, action, 2, properties, coordinates,
      0, 0, 1f, 1f, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
    try { assertTrue(overlay.dispatchTouchEvent(event)) } finally { event.recycle() }
  }

  @Test
  fun replacementCancelsPlacementPanAndConsumesTheOldStream() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        fun send(action: Int, x: Float, time: Long) {
          val event = MotionEvent.obtain(5_500L, time, action, x, 150f, 0)
          try { assertTrue(overlay.dispatchTouchEvent(event)) } finally { event.recycle() }
        }
        send(MotionEvent.ACTION_DOWN, 150f, 5_500L)
        send(MotionEvent.ACTION_MOVE, 200f, 5_520L)
        overlay.cancelForDocumentReplacement()
        harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
        val focus = harness.surface.currentViewportState().focus
        send(MotionEvent.ACTION_MOVE, 250f, 5_540L)
        send(MotionEvent.ACTION_UP, 250f, 5_560L)
        assertEquals(focus, harness.surface.currentViewportState().focus)
        assertEquals(0, editorCount(overlay))
      } finally { overlay.dispose() }
    }
  }

  @Test
  fun placementDragPansWithoutCreatingAnEditorAndLeavesPlacementArmed() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        val before = harness.surface.currentViewportState().focus
        listOf(
          Triple(MotionEvent.ACTION_DOWN, 150f, 5_500L),
          Triple(MotionEvent.ACTION_MOVE, 200f, 5_520L),
          Triple(MotionEvent.ACTION_UP, 200f, 5_540L),
        ).forEach { (action, x, time) ->
          val event = MotionEvent.obtain(5_500L, time, action, x, 150f, 0)
          try { assertTrue(overlay.dispatchTouchEvent(event)) } finally { event.recycle() }
        }
        assertEquals(InteractionMode.TEXTADD, overlay.interactionMode())
        assertEquals(0, editorCount(overlay))
        assertTrue(harness.surface.currentViewportState().focus.x != before.x)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 5_560L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, 5_580L))
        assertEquals(1, editorCount(overlay))
      } finally { overlay.dispose() }
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
        assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
        assertEquals(1, editorCount(overlay))
        val editor = editorView(overlay)
        val panStart = listOf(
          0f to 0f,
          (overlay.width - 1).toFloat() to 0f,
          0f to (overlay.height - 1).toFloat(),
          (overlay.width - 1).toFloat() to (overlay.height - 1).toFloat(),
        ).firstOrNull { (x, y) ->
          x < editor.left || x > editor.right || y < editor.top || y > editor.bottom
        }
        assertNotNull("No point outside the measured editor is available", panStart)
        val (panStartX, panStartY) = checkNotNull(panStart)
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

        assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
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
        assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
        assertEquals(1, editorCount(overlay))
        val editor = editorView(overlay)
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
        val wrappingText = "שלום ".repeat(6).trimEnd()
        editor.setText(wrappingText)
        assertEquals(wrappingText, editor.text.toString())
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
  fun autoDirectionUsesAppLayoutPolicyAndStaysFixedWhileTyping() {
    listOf(
      View.LAYOUT_DIRECTION_LTR to false,
      View.LAYOUT_DIRECTION_RTL to true,
    ).forEachIndexed { index, (layoutDirection, expectedRtl) ->
      harness.runOnMain {
        harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
        harness.surface.layoutDirection = layoutDirection
        val overlay = harness.createOverlay()
        try {
          overlay.setTextDirection(TextDirection.AUTO)
          overlay.armPlacement(1L)
          val time = 5_500L + index * 100L
          assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, time))
          assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, time + 10L))
          val editor = editorView(overlay)
          val expectedViewDirection = if (expectedRtl) {
            TextView.TEXT_DIRECTION_RTL
          } else {
            TextView.TEXT_DIRECTION_LTR
          }
          assertEquals(expectedViewDirection, editor.textDirection)

          editor.setText(if (expectedRtl) "Latin first" else "שלום קודם")
          assertEquals(expectedViewDirection, editor.textDirection)
          editor.setText("")
          assertEquals(expectedViewDirection, editor.textDirection)
          editor.setText(if (expectedRtl) "Latin after clear" else "שלום אחרי מחיקה")
          assertEquals(expectedViewDirection, editor.textDirection)
          overlay.finishForLifecycle()

          val saved = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
          assertEquals(expectedRtl, saved.directionRtl)
          val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
          val tap = presentation.transform.map(
            PagePoint(
              (saved.bounds.left + saved.bounds.right) / 2.0,
              (saved.bounds.top + saved.bounds.bottom) / 2.0,
            ),
          )
          assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), time + 20L))
          assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), time + 30L))
          assertEquals(expectedViewDirection, editorView(overlay).textDirection)
        } finally {
          overlay.dispose()
        }
      }
    }
  }

  @Test
  fun setTextDirectionUpdatesActiveDraftAndPersistsAfterReopen() {
    listOf(
      TextDirection.LTR to false,
      TextDirection.RTL to true,
    ).forEachIndexed { index, (direction, expectedRtl) ->
      harness.runOnMain {
        harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
        harness.surface.layoutDirection = if (expectedRtl) {
          View.LAYOUT_DIRECTION_LTR
        } else {
          View.LAYOUT_DIRECTION_RTL
        }
        val overlay = harness.createOverlay()
        try {
          overlay.setTextDirection(TextDirection.AUTO)
          overlay.armPlacement(1L)
          val time = 5_800L + index * 100L
          assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, time))
          assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, time + 10L))
          val editor = editorView(overlay)
          var expectedText = "Direction remains active"
          editor.setText(expectedText)
          val beforeBounds = editorPageBounds(editor)

          overlay.setTextDirection(direction)

          assertEquals("Direction remains active", editor.text.toString())
          assertEquals(
            if (expectedRtl) TextView.TEXT_DIRECTION_RTL else TextView.TEXT_DIRECTION_LTR,
            editor.textDirection,
          )
          assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
          val draft = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
          assertEquals(expectedRtl, draft.directionRtl)
          assertEquals(expectedText, draft.text.replace("\n", ""))
          val switchedBounds = editorPageBounds(editor)
          assertFrameNear(beforeBounds, switchedBounds)
          overlay.syncContent()
          assertFrameNear(beforeBounds, editorPageBounds(editor))

          val expansion = " with more text to expand"
          editor.append(expansion)
          expectedText += expansion
          val expandedBounds = editorPageBounds(editor)
          assertDirectionAnchorNear(switchedBounds, expandedBounds, expectedRtl)
          if (expectedRtl) assertTrue(expandedBounds.left <= switchedBounds.left + 2.0)
          else assertTrue(expandedBounds.right >= switchedBounds.right - 2.0)

          overlay.finishForLifecycle()
          val saved = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
          assertEquals(expectedRtl, saved.directionRtl)
          assertEquals(expectedText, saved.text.replace("\n", ""))
          harness.undo()
          assertTrue(checkNotNull(harness.surface.textPresentationSnapshot()).annotations.isEmpty())
          assertFalse(harness.coordinator.pageHistoryState(harness.surface.documentState.activePageIndex).canUndo)
          harness.core.redo(harness.surface.documentState.activePageId())
          assertEquals(saved, checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single())

          val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
          val tap = presentation.transform.map(
            PagePoint(
              (saved.bounds.left + saved.bounds.right) / 2.0,
              (saved.bounds.top + saved.bounds.bottom) / 2.0,
            ),
          )
          assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), time + 20L))
          assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), time + 30L))
          val reopened = editorView(overlay)
          assertEquals(saved.text, reopened.text.toString())
          assertEquals(
            if (expectedRtl) TextView.TEXT_DIRECTION_RTL else TextView.TEXT_DIRECTION_LTR,
            reopened.textDirection,
          )
        } finally {
          overlay.dispose()
        }
      }
    }
  }

  @Test
  fun autoDirectionUpdatesActiveEditorFromCurrentAppLayout() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      harness.surface.layoutDirection = View.LAYOUT_DIRECTION_LTR
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 6_000L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, 6_010L))
        val editor = editorView(overlay)
        editor.setText("Auto direction updates now")
        val beforeBounds = editorPageBounds(editor)

        harness.surface.layoutDirection = View.LAYOUT_DIRECTION_RTL
        overlay.setTextDirection(TextDirection.AUTO)

        assertEquals("Auto direction updates now", editor.text.toString())
        assertEquals(TextView.TEXT_DIRECTION_RTL, editor.textDirection)
        val draft = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertTrue(draft.directionRtl)
        assertEquals("Auto direction updates now", draft.text.replace("\n", ""))
        assertFrameNear(beforeBounds, editorPageBounds(editor))

        overlay.finishForLifecycle()
        val saved = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertTrue(saved.directionRtl)
        assertEquals("Auto direction updates now", saved.text.replace("\n", ""))
        harness.undo()
        assertTrue(checkNotNull(harness.surface.textPresentationSnapshot()).annotations.isEmpty())
        assertFalse(harness.coordinator.pageHistoryState(harness.surface.documentState.activePageIndex).canUndo)
        harness.core.redo(harness.surface.documentState.activePageId())
        assertEquals(saved, checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single())
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun directionSwitchNearPageEdgeKeepsTheWholeEditorFrame() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      harness.surface.layoutDirection = View.LAYOUT_DIRECTION_LTR
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 250f, 150f, 6_050L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 250f, 150f, 6_060L))
        val editor = editorView(overlay)
        editor.setText("Text near the right page edge")
        val beforeBounds = editorPageBounds(editor)

        overlay.setTextDirection(TextDirection.RTL)

        assertEquals(TextView.TEXT_DIRECTION_RTL, editor.textDirection)
        assertFrameNear(beforeBounds, editorPageBounds(editor))
        overlay.syncContent()
        assertFrameNear(beforeBounds, editorPageBounds(editor))
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun setTextDirectionUpdatesReopenedProgrammaticFlowBoundsEditor() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      val overlay = harness.createOverlay()
      try {
        harness.insertText(
          TextAnnotationBounds(80.0, 70.0, 160.0, 90.0),
          "Programmatic flow text",
          TextAnnotationOptions(untracked = null, font = null,
            fontSize = null,
            color = null,
            direction = TextDirection.LTR,
            maxLines = null,
            alignment = TextAlignment.START,
            verticalAnchor = null,
          ),
        )
        val original = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        val initialPresentation = checkNotNull(harness.surface.textPresentationSnapshot())
        val tap = initialPresentation.transform.map(
          PagePoint(
            (original.bounds.left + original.bounds.right) / 2.0,
            (original.bounds.top + original.bounds.bottom) / 2.0,
          ),
        )
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 6_100L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 6_110L))
        val editor = editorView(overlay)
        val beforeBounds = editorPageBounds(editor)

        overlay.setTextDirection(TextDirection.RTL)

        assertEquals("Programmatic flow text", editor.text.toString())
        assertEquals(TextView.TEXT_DIRECTION_RTL, editor.textDirection)
        val draft = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertTrue(draft.directionRtl)
        assertEquals(original.flowBounds, draft.flowBounds)
        assertFrameNear(beforeBounds, editorPageBounds(editor))

        overlay.finishForLifecycle()
        val saved = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertTrue(saved.directionRtl)
        assertEquals(original.flowBounds, saved.flowBounds)
        harness.undo()
        assertEquals(original, checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single())
        harness.core.redo(harness.surface.documentState.activePageId())
        assertEquals(saved, checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single())

        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        val reopenTap = presentation.transform.map(
          PagePoint(
            (saved.bounds.left + saved.bounds.right) / 2.0,
            (saved.bounds.top + saved.bounds.bottom) / 2.0,
          ),
        )
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, reopenTap.x.toFloat(), reopenTap.y.toFloat(), 6_120L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, reopenTap.x.toFloat(), reopenTap.y.toFloat(), 6_130L))
        assertEquals(TextView.TEXT_DIRECTION_RTL, editorView(overlay).textDirection)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun setTextDirectionStillUpdatesArmedPlacement() {
    harness.runOnMain {
      harness.setDocument(harness.info, zoom = 1.0, fitToPage = false)
      harness.surface.layoutDirection = View.LAYOUT_DIRECTION_LTR
      val overlay = harness.createOverlay()
      try {
        overlay.armPlacement(1L)
        harness.surface.layoutDirection = View.LAYOUT_DIRECTION_RTL
        overlay.setTextDirection(TextDirection.AUTO)
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, 150f, 150f, 6_200L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, 150f, 150f, 6_210L))
        assertEquals(TextView.TEXT_DIRECTION_RTL, editorView(overlay).textDirection)
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun explicitDirectionOverridesAppLayoutPolicy() {
    harness.runOnMain {
      listOf(
        Triple(View.LAYOUT_DIRECTION_RTL, TextDirection.LTR, false),
        Triple(View.LAYOUT_DIRECTION_LTR, TextDirection.RTL, true),
      ).forEachIndexed { index, (layoutDirection, direction, expectedRtl) ->
        harness.surface.layoutDirection = layoutDirection
        val overlay = harness.createOverlay()
        try {
          overlay.setTextDirection(direction)
          overlay.armPlacement(1L)
          val x = if (index == 0) 80f else 220f
          val time = 5_600L + index * 40L
          assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, x, 80f, time))
          assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, x, 80f, time + 10L))
          val editor = editorView(overlay)
          editor.setText("1")
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
        overlay.armPlacement(1L, TextModeOptions(font = null,
          direction = TextDirection.LTR, width = 80.0, height = 120.0,
          maxLines = null, alignment = TextAlignment.START, verticalAnchor = TextVerticalAnchor.TOP,
          x = null, y = null, zoom = null))
        val presentation = checkNotNull(harness.surface.textPresentationSnapshot())
        val tap = presentation.transform.map(PagePoint(150.0, 150.0))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tap.x.toFloat(), tap.y.toFloat(), 6_000L))
        assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tap.x.toFloat(), tap.y.toFloat(), 6_010L))
        val editor = editorView(overlay)
        val text = "wrap ".repeat(6).trimEnd()
        editor.setText(text)
        assertEquals(text, editor.text.toString())
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
        // Native pixel layout and page-point layout round metrics at different scales.
        assertEquals(
          nativeHeightInPageUnits,
          annotation.intrinsicHeight,
          1.0,
        )
      } finally {
        overlay.dispose()
      }
    }
  }

  @Test
  fun measuredEmptyEditorLogicalStartAndTopMatchTap() {
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
        val emptyContentWidth = editor.width - editor.compoundPaddingLeft - editor.compoundPaddingRight
        assertEquals(editor.textSize, emptyContentWidth.toFloat(), 1.5f)
        val tapInView = checkNotNull(harness.surface.textPresentationSnapshot())
          .transform.map(pageTap)
        assertEquals(tapInView.x.toFloat(), (editor.left + editor.compoundPaddingLeft).toFloat(), 1f)
        assertEquals(tapInView.y.toFloat(), (editor.top + editor.compoundPaddingTop).toFloat(), 1f)
      }
    } finally {
      harness.runOnMain { overlay.dispose() }
    }
  }

  @Test
  fun measuredEmptyEditorKeepsTopWhenTapIsNearPageEdge() {
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
        assertEquals(pageTap.y, frameTop, 1.0)
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
    var endFocus = 0.0
    var stableLeftAnchor = 0.0
    val text = "A".repeat(12)
    val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
    val viewportWidthPx = (300f * density).toInt()
    val viewportHeightPx = (300f * density).toInt()
    harness.runOnMain {
      harness.setSurfaceSize(viewportWidthPx, viewportHeightPx)
      harness.setDocument(harness.info, zoom = 3.0, fitToPage = false)
      overlay = harness.createOverlay()
      overlay.setTextDirection(TextDirection.LTR)
      overlay.armPlacement(1L)
      val initialTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
      val inverseTap = initialTransform.inverse().map(
        PagePoint(viewportWidthPx / 2.0, viewportHeightPx / 2.0),
      )
      pageAnchor = PagePoint(inverseTap.x, inverseTap.y)
      initialZoom = harness.surface.currentViewportState().zoom
      val tapX = viewportWidthPx / 2f
      val tapY = viewportHeightPx / 2f
      assertTrue(dispatch(overlay, MotionEvent.ACTION_DOWN, tapX, tapY, 7_000L))
      assertTrue(dispatch(overlay, MotionEvent.ACTION_UP, tapX, tapY, 7_010L))
      assertEquals(InteractionMode.TEXTEDIT, overlay.interactionMode())
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
          .map(PagePoint((editor.left + editor.compoundPaddingLeft).toDouble(), editor.top.toDouble())).x

        editor.setText(text)
        overlay.syncTransform()
        assertEquals(initialZoom, harness.surface.currentViewportState().zoom, 0.0)
        val latinTransform = checkNotNull(harness.surface.textPresentationSnapshot()).transform
        val leftAnchorWithLatin = latinTransform.inverse()
          .map(PagePoint((editor.left + editor.compoundPaddingLeft).toDouble(), editor.top.toDouble())).x
        assertEquals(leftAnchorWithHebrew, leftAnchorWithLatin, 2.0)
        stableLeftAnchor = leftAnchorWithLatin

        editor.setSelection(0, text.length)
        overlay.syncTransform()
      }
      harness.waitForDetachedCaretFollow()
      harness.runOnMain {
        val editor = editorView(overlay)
        assertEquals(initialZoom, harness.surface.currentViewportState().zoom, 0.0)
        endFocus = harness.surface.currentViewportState().focus.x
        assertCaretIsInsideView(editor, editor.selectionEnd, overlay.width, overlay.height)

        editor.setSelection(1, text.length)
        assertCaretIsOutsideView(editor, editor.selectionStart, overlay.width, overlay.height)
        overlay.syncTransform()
      }
      harness.waitForDetachedCaretFollow()
      harness.runOnMain {
        val editor = editorView(overlay)
        val startFocus = harness.surface.currentViewportState().focus.x
        assertTrue(startFocus < endFocus)
        assertCaretIsInsideView(editor, editor.selectionStart, overlay.width, overlay.height)

        editor.setSelection(1)
        overlay.syncTransform()
      }
      harness.waitForDetachedCaretFollow()
      harness.runOnMain {
        val editor = editorView(overlay)
        assertCaretIsInsideView(editor, editor.selectionStart, overlay.width, overlay.height)
        overlay.finishForLifecycle()
        val annotation = checkNotNull(harness.surface.textPresentationSnapshot()).annotations.single()
        assertTrue(!annotation.directionRtl)
        assertEquals(stableLeftAnchor, annotation.bounds.left, 1.0)
        assertEquals(pageAnchor.y, annotation.bounds.top, 1.0)
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
        id = 1L,
        text = "Hello",
        bounds = PageRect(80.0, 80.0, 140.0, 100.0),
        fontSize = 16.0,
      )
      appendTestText(annotation)
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

  private fun dispatchTouch(
    overlay: TextInteractionOverlay,
    action: Int,
    x: Float,
    y: Float,
    downTime: Long,
    eventTime: Long,
  ): Boolean {
    val event = MotionEvent.obtain(downTime, eventTime, action, x, y, 0)
    return try {
      overlay.dispatchTouchEvent(event)
    } finally {
      event.recycle()
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

  private fun textPixelBounds(bitmap: Bitmap, region: Rect): Rect? {
    var bounds: Rect? = null
    for (y in region.top.coerceAtLeast(0) until region.bottom.coerceAtMost(bitmap.height)) {
      for (x in region.left.coerceAtLeast(0) until region.right.coerceAtMost(bitmap.width)) {
        val pixel = bitmap.getPixel(x, y)
        if (android.graphics.Color.alpha(pixel) > 0 && android.graphics.Color.red(pixel) < 80 &&
          android.graphics.Color.green(pixel) < 80 && android.graphics.Color.blue(pixel) < 80) {
          if (bounds == null) bounds = Rect(x, y, x + 1, y + 1)
          else bounds?.union(x, y, x + 1, y + 1)
        }
      }
    }
    return bounds
  }

  private fun editorCount(overlay: TextInteractionOverlay): Int =
    (0 until overlay.childCount).count { overlay.getChildAt(it) is EditText }

  private fun editorView(overlay: TextInteractionOverlay): EditText =
    (0 until overlay.childCount)
      .map(overlay::getChildAt)
      .filterIsInstance<EditText>()
      .single()

  private fun editorPageBounds(editor: EditText): PageRect {
    val inverse = checkNotNull(harness.surface.textPresentationSnapshot()).transform.inverse()
    val corners = listOf(
      editor.left to editor.top,
      editor.right to editor.top,
      editor.left to editor.bottom,
      editor.right to editor.bottom,
    ).map { (x, y) -> inverse.map(PagePoint(x.toDouble(), y.toDouble())) }
    return PageRect(
      corners.minOf { it.x },
      corners.minOf { it.y },
      corners.maxOf { it.x },
      corners.maxOf { it.y },
    )
  }

  private fun assertDirectionAnchorNear(before: PageRect, after: PageRect, isRtl: Boolean) {
    val anchoredEdgeBefore = if (isRtl) before.right else before.left
    val anchoredEdgeAfter = if (isRtl) after.right else after.left
    assertEquals(anchoredEdgeBefore, anchoredEdgeAfter, 2.0)
    assertEquals(before.top, after.top, 2.0)
  }

  private fun assertFrameNear(before: PageRect, after: PageRect) {
    assertEquals(before.left, after.left, 2.0)
    assertEquals(before.top, after.top, 2.0)
    assertEquals(before.right, after.right, 2.0)
    assertEquals(before.bottom, after.bottom, 2.0)
  }

  private suspend fun openCandidate(source: java.io.File): PdfSessionInfo =
    withContext(Dispatchers.Main.immediate) {
      val pending = harness.coordinator.prepareOpen(null, { error("Unexpected fallback font") },
        { source.copyTo(it, overwrite = true) })
      val info = try { harness.coordinator.commitOpen(pending) }
        finally { harness.coordinator.finishOpen(pending) }
      harness.surface.installDocumentPresentation(zoom = null, focus = null, fitToPage = true)
      info
    }

  private fun choosePlacementDirection(overlay: TextInteractionOverlay, rtl: Boolean) {
    overlay.setTextDirection(if (rtl) TextDirection.RTL else TextDirection.LTR)
  }

  private fun assertCaretIsInsideView(editor: EditText, offset: Int, widthPx: Int, heightPx: Int) {
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
    assertTrue("Caret and adjacent outline must be inside the 24 dp margin; $details", outlineRight <= widthPx - marginPx)
    assertTrue("Caret and adjacent outline must be inside the 24 dp margin; $details", outlineTop >= marginPx)
    assertTrue("Caret and adjacent outline must be inside the 24 dp margin; $details", outlineBottom <= heightPx - marginPx)
  }

  private fun assertCaretIsOutsideView(editor: EditText, offset: Int, widthPx: Int, heightPx: Int) {
    val (caretX, caretTop) = caretViewPosition(editor, offset)
    val marginPx = 24f * InstrumentationRegistry.getInstrumentation()
      .targetContext.resources.displayMetrics.density
    assertTrue(
      "The moved selection endpoint must start outside the 24 dp margin, got x=$caretX y=$caretTop",
      caretX < marginPx || caretX > widthPx - marginPx || caretTop < marginPx || caretTop > heightPx - marginPx,
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

  private fun appendTestText(annotation: TextAnnotation): TextAnnotation {
    val coordinator = harness.coordinator
    val page = coordinator.page(0)
    val slot = coordinator.reserveTextTarget(
      page.id,
      sourceIdentity = null,
      fieldName = null,
      canonicalBounds = annotation.canonicalPlacementBounds,
      options = null,
    )
    assertEquals(annotation.id, slot.id)
    val registered = annotation.copy(id = slot.id)
    harness.core.text.applyEdit(DocumentPageContext(coordinator.generation, page.id), null, registered)
    return registered
  }

  private inner class TextSurfaceHarness {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val pages = listOf(
      PdfPageDimensions(300.0, 300.0),
      PdfPageDimensions(300.0, 300.0),
    )
    val executor = Executors.newSingleThreadExecutor()
    val openedResources = mutableListOf<EmptyPdfResource>()
    val worker = PdfSessionWorker(
      opener = PdfSessionOpener { path, openedGeneration ->
        val contents = java.io.File(path).takeIf { it.isFile }?.readText().orEmpty()
        val openedPages = when (contents) {
          "open-a" -> listOf(PdfPageDimensions(220.0, 180.0))
          "open-b" -> listOf(PdfPageDimensions(160.0, 120.0))
          else -> pages
        }
        EmptyPdfResource(PdfSessionInfo(path, openedPages, openedGeneration))
          .also(openedResources::add)
      },
      executorOverride = executor,
    )
    private val engine = InkEngine()
    val core = DocumentCore(
      instrumentation.targetContext, worker, recordHistory = true, exportOwnership = ExportOwnership.DOCUMENT,
    )
    val coordinator get() = core.coordinator
    fun activeHistoryRevision(): Long = coordinator.pageHistoryRevision(surface.documentState.activePageIndex)
    fun undo() {
      surface.prepareContentMutation()
      core.undo(surface.documentState.activePageId())
    }
    lateinit var surface: ViewerCanvas
    var overlay: TextInteractionOverlay? = null
    val info: PdfSessionInfo

    init {
      val created = java.util.concurrent.atomic.AtomicReference<ViewerCanvas>()
      instrumentation.runOnMainSync {
        created.set(
          ViewerCanvas(
            instrumentation.targetContext,
            engine,
            core = core,
          ),
        )
        surface = created.get()
        surface.layout(0, 0, 300, 300)
      }
      info = runBlocking {
        withContext(Dispatchers.Main) {
          val pending = coordinator.prepareOpen(null, { error("Unexpected fallback font") }, { it.writeText("initial") })
          try { coordinator.commitOpen(pending) }
          finally { coordinator.finishOpen(pending) }
        }
      }
      runOnMain {
        setDocument(info)
        core.observe { change ->
          when (change) {
            is DocumentChange.Text -> surface.refreshCommittedText(change.pageId)
            is DocumentChange.Content -> surface.presentContentChange(change)
            else -> Unit
          }
        }
      }
    }

    fun setSurfaceSize(widthPx: Int, heightPx: Int) {
      surface.layout(0, 0, widthPx, heightPx)
    }

    fun insertText(bounds: TextAnnotationBounds, text: String, options: TextAnnotationOptions?) {
      val presentation = checkNotNull(surface.textPresentationSnapshot())
      core.text.insert(DocumentPageContext(presentation.generation, presentation.pageId), bounds, text, options,
        directionRtl = checkNotNull(overlay).resolveDirection(options?.direction))
    }

    fun createOverlay(): TextInteractionOverlay {
      val overlay = TextInteractionOverlay(
        instrumentation.targetContext,
        surface,
        core,
      )
      this.overlay = overlay
      surface.onTextContentChanged = overlay::syncContent
      surface.onTextTransformChanged = overlay::syncTransform
      overlay.layout(0, 0, surface.width, surface.height)
      overlay.syncContent()
      return overlay
    }

    fun setDocument(
      next: PdfSessionInfo,
      zoom: Double? = null,
      focus: PagePoint? = null,
      fitToPage: Boolean = true,
    ) {
      val pages = next.pages.map { dimensions ->
        InkPageState(PageRecord.newId(), dimensions)
      }
      coordinator.installCandidate(next.sourcePath, pages)
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

    fun waitForDetachedCaretFollow(timeoutMs: Long = 5_000L) {
      val callbackWindowElapsed = CountDownLatch(1)
      android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(
        callbackWindowElapsed::countDown,
        64L,
      )
      assertTrue(
        "Detached caret follow did not run before the selection visibility check",
        callbackWindowElapsed.await(timeoutMs, TimeUnit.MILLISECONDS),
      )
      waitForViewportAnimationToFinish(timeoutMs)
    }

    fun close() {
      runOnMain {
        overlay?.dispose()
        overlay = null
        surface.clearDocument()
      }
      engine.close()
      runBlocking { core.close(cancelPending = true).await() }
    }
  }

  private class EmptyPdfResource(
    override val info: PdfSessionInfo,
  ) : PdfSessionResource {
    @Volatile var closed = false
      private set
    @Volatile var renderCount = 0
      private set
    val snapCandidateRequests = java.util.concurrent.CopyOnWriteArrayList<Int>()

    override fun canonicalWritingRules(pageIndex: Int): List<PdfiumPreparedRule> {
      snapCandidateRequests += pageIndex
      return emptyList()
    }

    override fun renderTiles(
      requests: List<PdfTileRequest>,
      beforeEach: () -> Unit,
    ): List<PdfTile> {
      renderCount += 1
      requests.forEach { beforeEach() }
      return emptyList()
    }

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

    override fun close() { closed = true }
  }

  private class CommitGate {
    private val started = CountDownLatch(1)
    private val releaseSignal = CountDownLatch(1)

    fun awaitStarted() {
      assertTrue("worker did not reach the prepared-open commit", started.await(5L, TimeUnit.SECONDS))
    }

    fun awaitRelease() {
      started.countDown()
      check(releaseSignal.await(5L, TimeUnit.SECONDS)) { "test did not release the prepared-open commit" }
    }

    fun release() { releaseSignal.countDown() }
  }
}
