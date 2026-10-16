package com.margelo.nitro.inksignpdf

import android.view.View
import android.view.MotionEvent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Canvas
import android.widget.EditText
import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import android.widget.FrameLayout
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.margelo.nitro.core.Promise
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PageRotationInstrumentationTest {
  @Test
  fun savedRotationRetainsOneCanonicalUnderlineAndTargetIdentity() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    for (saved in listOf(0, 90, 180, 270)) {
      val source = File.createTempFile("canonical-rotation-", ".pdf", context.cacheDir).apply {
        writeBytes(sourcePdf(320, 400, fieldRules = true, savedRotation = saved, oneRule = true))
      }
      val document = await(instrumentation, HybridInkSignDocument(context).open(source.absolutePath, null))
      try {
        val page = await(instrumentation, document.getPage(PageQuery.create(0.0)))
        var originalId: Double? = null
        if (saved == 90 || saved == 270) {
          try {
            page.resolveInputTarget(fieldResolutionOptions())
            throw AssertionError("Sideways underline unexpectedly resolved")
          } catch (error: PdfSessionException) {
            assertEquals("Label must survive saved rotation", "text_rule_not_found", error.code)
          }
        } else {
          originalId = page.resolveInputTarget(fieldResolutionOptions().copy(
            direction = if (saved == 180) TextDirection.RTL else TextDirection.LTR))
        }
        if (saved != 0) await(instrumentation, document.rotatePage(0.0, (360 - saved).toDouble()))
        val uprightId = page.resolveInputTarget(fieldResolutionOptions())
        if (originalId != null) assertEquals("Returning upright must retain the target ID", originalId, uprightId, 0.0)
        await(instrumentation, document.rotatePage(0.0, 90.0))
        await(instrumentation, document.rotatePage(0.0, 270.0))
        assertEquals(uprightId, page.resolveInputTarget(fieldResolutionOptions()), 0.0)
        assertEquals("Name", page.getInputTarget(uprightId).fieldName)
      } finally {
        await(instrumentation, document.close())
        source.delete()
      }
    }
  }

  @Test
  fun deferredRotationPreservesTextLayoutAndCommitsNewTextUpright() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("rotation-text-", ".pdf", context.cacheDir)
    val viewRef = AtomicReference<HybridInkSignView>()
    val document = HybridInkSignDocument(context)
    try {
      source.writeBytes(sourcePdf(width = 320, height = 240))
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context).also { it.document = document }
        viewRef.set(view)
        val size = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        view.view.measure(size, size)
        view.view.layout(0, 0, 480, 480)
      }
      await(instrumentation, document.open(source.absolutePath, null))
      val initialPage = awaitPreparedPage(instrumentation, viewRef.get())
      val before = AtomicReference<TextAnnotation>()
      val workingPath = AtomicReference<String>()
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        workingPath.set(view.documentState.sourcePath)
        setPreparedText(initialPage, TextAnnotationBounds(40.0, 50.0, 180.0, 24.0), "Original")
        before.set(view.documentState.pageSnapshot(0).content.single().textAnnotationOrNull())
      }
      await(instrumentation, document.rotatePage(0.0, 90.0))
      val rotatedPage = awaitPreparedPage(instrumentation, viewRef.get())
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        assertEquals(workingPath.get(), view.documentState.sourcePath)
        assertEquals(PdfPageDimensions(320.0, 240.0, 0), view.documentState.pageMetadata(0).sourceDimensions)
        val container = view.view as FrameLayout
        val surface = container.getChildAt(0) as ViewerCanvas
        val overlay = (0 until container.childCount).map(container::getChildAt)
          .filterIsInstance<TextInteractionOverlay>().single()
        overlay.syncContent()
        val annotation = before.get()
        val point = checkNotNull(surface.textPresentationSnapshot()).forAnnotation(annotation)
          .transform.map(PagePoint(80.0, 60.0))
        val now = android.os.SystemClock.uptimeMillis()
        for ((action, time) in listOf(MotionEvent.ACTION_DOWN to now, MotionEvent.ACTION_UP to now + 20)) {
          val event = MotionEvent.obtain(now, time, action, point.x.toFloat(), point.y.toFloat(), 0)
          try { overlay.onTouchEvent(event) } finally { event.recycle() }
        }
        val editor = overlay.getChildAt(0) as EditText
        assertEquals(90.0, editor.rotation.toDouble(), 0.001)
        assertTrue("Editing must retain the original horizontal layout width", editor.width > editor.height)
        editor.setText("Edited")
        view.setMode(InputMode.VIEW, null)
        val edited = checkNotNull(view.documentState.pageSnapshot(0).content.single().textAnnotationOrNull())
        assertEquals(annotation.flowBounds, edited.flowBounds)
        assertEquals(annotation.layoutPage, edited.layoutPage)

        view.defaultTextColor = "#D00000"
        setPreparedText(rotatedPage, TextAnnotationBounds(60.0, 160.0, 160.0, 24.0), "New text",
          TextAnnotationOptions(untracked = null, font = null, fontSize = null, color = "#D00000",
            direction = null, maxLines = null, alignment = null, verticalAnchor = null))
        val newText = checkNotNull(view.documentState.pageSnapshot(0).content.last().textAnnotationOrNull())
        assertEquals(PdfPageDimensions(240.0, 320.0, 1), newText.layoutPage)
        val actual = Bitmap.createBitmap(240, 320, Bitmap.Config.ARGB_8888)
        val expected = Bitmap.createBitmap(240, 320, Bitmap.Config.ARGB_8888)
        try {
          val canvas = Canvas(actual)
          canvas.concat(PageCoordinates(view.documentState.pageMetadata(0).dimensions)
            .rawToView(PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)).toCanvasMatrix())
          TextRenderLayer.from(listOf(newText)).draw(canvas)
          TextRenderLayer.from(listOf(newText.copy(layoutPage = null))).draw(Canvas(expected))
          assertTrue("Committed rendering must match the upright insertion layout", actual.sameAs(expected))
        } finally {
          actual.recycle()
          expected.recycle()
        }
      }
      val output = await(instrumentation, document.finalize())
      try {
        val exported = PdfiumRenderSession.open(File(java.net.URI(output)).readBytes())
        try {
          assertEquals(PdfiumPageSize(240.0, 320.0, 1), exported.pageSize(0))
          val exportedAnalysis = exported.preparePageAnalysis(0)
          assertTrue("Export must retain the inserted text glyphs: ${glyphText(exportedAnalysis)}",
            glyphText(exportedAnalysis).contains("New text"))
          val rendered = Bitmap.createBitmap(240, 320, Bitmap.Config.ARGB_8888)
          try {
            assertTrue(exported.renderPageIntoBitmap(
              pageIndex = 0,
              bitmap = rendered,
              pageToDevice = PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
              clip = PdfiumRect(0.0, 0.0, 240.0, 320.0),
              flags = pdfiumAndroidDisplayFlags,
            ))
            val pixels = redPixelBounds(rendered)
            assertTrue("New text should remain upright after rotation", pixels.width() > pixels.height())
            assertTrue(
              "Exported text should remain inside the inserted field, with a small rasterization tolerance",
              pixels.left >= 58 && pixels.right <= 222 && pixels.top >= 158 && pixels.bottom <= 186,
            )
          } finally {
            rendered.recycle()
          }
        } finally { exported.close() }
      } finally { File(java.net.URI(output)).delete() }
    } finally {
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      source.delete()
    }
  }

  @Test
  fun preparedPageRetainsIdentityAndUsesCurrentGeometryAfterRotation() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("prepared-rotation-", ".pdf", context.cacheDir)
    val viewRef = AtomicReference<HybridInkSignView>()
    val document = HybridInkSignDocument(context)
    try {
      source.writeBytes(sourcePdf(300, 400, fieldRules = true))
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context).also { it.document = document }
        viewRef.set(view)
        val size = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        view.view.measure(size, size)
        view.view.layout(0, 0, 480, 480)
      }
      await(instrumentation, document.open(source.absolutePath, null))
      val capturedPage = awaitPreparedPage(instrumentation, viewRef.get())
      await(instrumentation, document.rotatePage(0.0, 90.0))
      await(instrumentation, document.rotatePage(0.0, 90.0))

      val id = capturedPage.resolveInputTarget(fieldResolutionOptions())
      capturedPage.setTextValue(id, "OK", null)
      val currentPage = awaitPreparedPage(instrumentation, viewRef.get())
      assertEquals(id, currentPage.resolveInputTarget(fieldResolutionOptions()), 0.0)
      await(instrumentation, viewRef.get().focusInputTarget(currentPage, id, InputTargetFocusOptions(
        zoom = 5.0,
        verticalAnchor = FieldFocusVerticalAnchor.BOTTOM,
        edgeOffset = 8.0,
      )))
      instrumentation.runOnMainSync {
        val annotation = checkNotNull(
          viewRef.get().documentState.pageSnapshot(0).content.single().textAnnotationOrNull(),
        )
        assertEquals("OK", annotation.text)
        assertEquals(2, annotation.layoutPage?.rotation)
      }
    } finally {
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      source.delete()
    }
  }

  @Test
  fun fieldCommandsPairDisplayedRulesAndRejectVerticalRules() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("rotation-fields-", ".pdf", context.cacheDir)
    val viewRef = AtomicReference<HybridInkSignView>()
    val document = HybridInkSignDocument(context)
    try {
      source.writeBytes(sourcePdf(300, 400, fieldRules = true))
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context).also { it.document = document }
        viewRef.set(view)
        val size = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        view.view.measure(size, size)
        view.view.layout(0, 0, 480, 480)
        view.defaultTextColor = "#D00000"
      }
      await(instrumentation, document.open(source.absolutePath, null))
      var stableId: Double? = null
      for (rotationStep in listOf(0, 90, 180, 270, 360)) {
        val angle = rotationStep % 360
        val view = viewRef.get()
        if (rotationStep != 0) await(instrumentation, document.rotatePage(0.0, 90.0))
        val page = awaitPreparedPage(instrumentation, view)
        if (angle == 90 || angle == 270) {
          try {
            page.resolveInputTarget(fieldResolutionOptions())
            throw AssertionError("A vertical rule must not resolve as a field")
          } catch (error: PdfSessionException) {
            assertEquals("text_rule_not_found", error.code)
          }
          try {
            await(instrumentation, view.focusInputTarget(page, checkNotNull(stableId), InputTargetFocusOptions(
              zoom = 5.0,
              verticalAnchor = FieldFocusVerticalAnchor.BOTTOM,
              edgeOffset = 8.0,
            )))
            throw AssertionError("A vertical rule must not accept focus")
          } catch (error: AssertionError) {
            assertEquals("text_rule_not_found", (error.cause as? PdfSessionException)?.code)
          }
          instrumentation.runOnMainSync {
            assertTrue(view.documentState.pageSnapshot(0).content.isEmpty())
            val surface = (view.view as FrameLayout).getChildAt(0) as ViewerCanvas
            assertTrue(!surface.isEditMode)
          }
          continue
        }
        val id = page.resolveInputTarget(fieldResolutionOptions())
        if (angle == 180) {
          assertTrue("The opposite source rule must have a distinct target", id != checkNotNull(stableId))
        } else {
          stableId?.let { assertEquals("Returning to the same source rule must reuse its ID", it, id, 0.0) }
            ?: run { stableId = id }
        }
        page.setTextValue(id, "OK", TextAnnotationOptions(untracked = null, font = null, fontSize = null,
          color = "#D00000", direction = null, maxLines = null, alignment = null, verticalAnchor = null))
        val ruleY = if (angle == 0) 132.0 else 268.0
        val field = PageRect(if (angle == 0) 210.0 else 190.0, 0.0, 280.0, ruleY)
        instrumentation.runOnMainSync {
          val annotation = checkNotNull(view.documentState.pageSnapshot(0).content.single().textAnnotationOrNull())
          assertEquals(field, annotation.flowBounds)
          assertEquals(angle / 90, annotation.layoutPage?.rotation)
        }
        for (anchor in listOf(FieldFocusVerticalAnchor.TOP, FieldFocusVerticalAnchor.BOTTOM)) {
          await(instrumentation, view.focusInputTarget(page, id, InputTargetFocusOptions(
            zoom = 5.0,
            verticalAnchor = anchor,
            edgeOffset = 8.0,
          )))
          instrumentation.runOnMainSync {
            val surface = (view.view as FrameLayout).getChildAt(0) as ViewerCanvas
            val state = surface.currentViewportState()
            val halfHeight = surface.height / (2.0 * state.zoom * context.resources.displayMetrics.density)
            val expected = if (anchor == FieldFocusVerticalAnchor.TOP) ruleY + halfHeight - 8 else ruleY - halfHeight + 8
            assertEquals(expected.coerceIn(halfHeight, 400.0 - halfHeight), state.focus.y, 0.01)
          }
        }
        val output = await(instrumentation, document.finalize())
        try {
          val exported = PdfiumRenderSession.open(File(java.net.URI(output)).readBytes())
          val bitmap = Bitmap.createBitmap(300, 400, Bitmap.Config.ARGB_8888)
          try {
            assertTrue(completeLabelMatches(
              preparedTextLabels(exported.preparePageAnalysis(0)), "OK",
            ).isNotEmpty())
            assertTrue(exported.renderPageIntoBitmap(0, bitmap,
              PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
              PdfiumRect(0.0, 0.0, 300.0, 400.0), flags = pdfiumAndroidDisplayFlags))
            val pixels = redPixelBounds(bitmap)
            assertTrue(pixels.width() > pixels.height())
            assertTrue(pixels.left >= field.left - 2 && pixels.right <= field.right + 2 &&
              pixels.top >= field.top - 2 && pixels.bottom <= field.bottom + 2)
          } finally { bitmap.recycle(); exported.close() }
        } finally { File(java.net.URI(output)).delete() }
        instrumentation.runOnMainSync { page.clear() }
      }
    } finally {
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      source.delete()
    }
  }

  private fun redPixelBounds(bitmap: Bitmap): android.graphics.Rect {
    var left = bitmap.width; var top = bitmap.height; var right = -1; var bottom = -1
    for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
      val pixel = bitmap.getPixel(x, y)
      if (android.graphics.Color.red(pixel) > android.graphics.Color.green(pixel) + 60 &&
        android.graphics.Color.red(pixel) > android.graphics.Color.blue(pixel) + 60) {
        left = minOf(left, x); top = minOf(top, y)
        right = maxOf(right, x); bottom = maxOf(bottom, y)
      }
    }
    assertTrue("Expected visible red insertion", right >= left && bottom >= top)
    return android.graphics.Rect(left, top, right + 1, bottom + 1)
  }

  private fun glyphText(analysis: PdfiumPreparedPageAnalysis): String = buildString {
    analysis.glyphs.forEach { appendCodePoint(it.codepoint) }
  }

  @Test
  fun pageInspectionExcludesImportedInkAndUsesDisplayedGeometryAfterReopen() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("page-inspection-", ".pdf", context.cacheDir)
    val view = AtomicReference<HybridInkSignView>()
    val document = HybridInkSignDocument(context)
    val pageEvents = ArrayList<PageChangeEvent>()
    var reopened: HybridInkSignDocumentSpec? = null
    val outputs = ArrayList<File>()
    try {
      source.writeBytes(sourcePdf(320, 240, importedInk = true))
      instrumentation.runOnMainSync {
        view.set(HybridInkSignView(context).also {
          it.document = document
          it.strokeColor = "#000000"
          it.onPageChange = { state -> pageEvents += state }
          val size = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
          it.view.measure(size, size)
          it.view.layout(0, 0, 480, 480)
        })
      }
      await(instrumentation, document.open(source.absolutePath,
        DocumentOpenOptions(null, "report", null, null, null, null)))
      val page = awaitPreparedPage(instrumentation, view.get())
      instrumentation.runOnMainSync {
        assertTrue("Imported PDF Ink annotations are not session ink", !page.getState().hasInk)
        assertTrue(!page.getState().hasText)
        assertTrue(!page.getState().isDirty)
        assertEquals(1.0, document.getState().pageCount, 0.0)
        assertEquals(0.0, page.getState().rotation, 0.0)
        document.core.commitInk(DocumentPageContext(view.get().documentState.generation,
          view.get().documentState.activePageId()), StrokeOutline.fromCommands(listOf(
          InkPathCommand(InkPathCommand.MOVE, 140f, 130f),
          InkPathCommand(InkPathCommand.LINE, 160f, 130f),
          InkPathCommand(InkPathCommand.LINE, 160f, 145f),
          InkPathCommand(InkPathCommand.LINE, 140f, 145f),
          InkPathCommand(InkPathCommand.CLOSE),
        )))
        assertTrue(page.getState().hasInk)
        assertTrue(page.getState().isDirty)
        assertTrue(page.getState().canUndo)
        assertEquals(page.getState().pageId, pageEvents.last().pageId)
        assertTrue(pageEvents.last().canUndo)
        page.undo()
        assertTrue(!page.getState().hasInk)
        page.redo()
        assertTrue(page.getState().hasInk)
      }
      await(instrumentation, document.addPages(DocumentAddPagesOptions(
        tag = "report", sources = arrayOf(source.absolutePath), imagePageSize = null,
        targetDpi = null, jpegQuality = null,
      )))
      val otherPage = await(instrumentation, document.getPage(PageQuery.create(1.0)))
      instrumentation.runOnMainSync {
        val surface = (view.get().view as FrameLayout).getChildAt(0) as ViewerCanvas
        surface.switchPage(1)
        assertTrue(!otherPage.getState().hasInk)
        assertTrue("Inspection must remain bound to the nonactive page", page.getState().hasInk)
        assertEquals(0.0, page.getState().pageIndex, 0.0)
        assertEquals(2.0, page.getState().pageCount, 0.0)
        assertEquals("report", page.getState().tag)
        assertEquals("report", otherPage.getState().tag)
        assertEquals(listOf(page.getState().pageId, otherPage.getState().pageId), document.getPageIdsByTag("report").toList())
        assertEquals(1, view.get().documentState.activePageIndex)
        surface.switchPage(0)
        assertTrue(document.getState().isDirty)
        assertTrue(page.getState().isDirty)
        assertTrue(page.getState().canUndo)
        assertEquals(page.getState().pageId, pageEvents.last().pageId)
        assertTrue(pageEvents.last().canUndo)
      }
      await(instrumentation, document.rotatePage(0.0, 90.0))
      instrumentation.runOnMainSync {
        assertEquals(240.0, page.getState().width, 0.0)
        assertEquals(320.0, page.getState().height, 0.0)
        assertEquals(90.0, page.getState().rotation, 0.0)
        assertTrue(page.getState().hasInk)
      }
      val uri = await(instrumentation, document.finalize())
      outputs += File(java.net.URI(uri))
      val reopenedDocument = await(instrumentation, HybridInkSignDocument(context, recordHistory = false).open(uri,
        DocumentOpenOptions(recordHistory = null, tag = "reopened", imagePageSize = null, targetDpi = null, jpegQuality = null,
          androidFallbackFont = null)))
      reopened = reopenedDocument
      val reopenedPage = await(instrumentation, reopenedDocument.getPage(PageQuery.create(TaggedPageQuery("reopened", null))))
      val stampBounds = TextAnnotationBounds(30.0, 60.0, 160.0, 30.0)
      instrumentation.runOnMainSync {
        assertTrue("Exported ink is imported content on reopen", !reopenedPage.getState().hasInk)
        assertTrue("Tags are not restored from exported PDF bytes", reopenedDocument.getPageIdsByTag("report").isEmpty())
        assertEquals(2, reopenedDocument.getPageIdsByTag("reopened").size)
        assertEquals("reopened", reopenedPage.getState().tag)
        assertEquals(2.0, reopenedDocument.getState().pageCount, 0.0)
        assertTrue(!reopenedDocument.getState().isDirty)
        val info = reopenedPage.getState()
        assertEquals(240.0, info.width, 0.0)
        assertEquals(320.0, info.height, 0.0)
        assertEquals(90.0, info.rotation, 0.0)
        val id = reopenedPage.resolveInputTarget(fieldResolutionOptions().copy(
          fieldName = null, bounds = stampBounds, fontSize = 16.0,
          color = "#D00000", verticalAnchor = TextVerticalAnchor.TOP))
        reopenedPage.setTextValue(id, "STAMP", null)
        assertTrue(!reopenedPage.getState().hasInk)
        assertTrue(reopenedPage.getState().hasText)
        assertTrue(!reopenedPage.getState().isDirty)
        assertTrue(!reopenedDocument.getState().isDirty)
        assertTrue("Headless documents do not record undo", !reopenedPage.getState().canUndo)
      }
      val stampedUri = await(instrumentation, reopenedDocument.finalize())
      outputs += File(java.net.URI(stampedUri))
      PdfiumRenderSession.open(outputs.last().readBytes()).use { exported ->
        assertEquals(PdfiumPageSize(240.0, 320.0, 1), exported.pageSize(0))
        val bitmap = Bitmap.createBitmap(240, 320, Bitmap.Config.ARGB_8888)
        try {
          assertTrue(exported.renderPageIntoBitmap(0, bitmap,
            PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
            PdfiumRect(0.0, 0.0, 240.0, 320.0), flags = pdfiumAndroidDisplayFlags))
          val stamp = redPixelBounds(bitmap)
          assertTrue("Stamp must use displayed top-left bounds: $stamp",
            stamp.left >= 28 && stamp.right <= 192 && stamp.top >= 58 && stamp.bottom <= 92)
          val inkCenter = PageCoordinates(PdfPageDimensions(240.0, 320.0, 1))
            .canonicalToDisplay(PagePoint(150.0, 137.0))
          assertEquals("Exported session ink must remain visible", Color.BLACK,
            bitmap.getPixel(inkCenter.x.toInt(), inkCenter.y.toInt()))
        } finally { bitmap.recycle() }
      }
    } finally {
      reopened?.let { await(instrumentation, it.close()) }
      instrumentation.runOnMainSync { view.get()?.onDropView() }
      outputs.forEach { it.delete() }
      source.delete()
    }
  }

  @Test
  fun rotationPreservesHistoryCancelsLiveInputAndPersistsExportedOrientation() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("rotation-source-", ".pdf", context.cacheDir)
    val viewRef = AtomicReference<HybridInkSignView>()
    val document = HybridInkSignDocument(context)
    val failure = AtomicReference<Throwable>()
    try {
      source.writeBytes(sourcePdf(width = 320, height = 240))
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context).also { it.document = document }
        viewRef.set(view)
        val exactSize = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        view.view.measure(exactSize, exactSize)
        view.view.layout(0, 0, 480, 480)
      }
      await(instrumentation, document.open(source.absolutePath, null))
      val preparedPage = awaitPreparedPage(instrumentation, viewRef.get())

      val originalPageId = AtomicReference<String>()
      val contentBeforeRotation = AtomicReference<List<PageContent>>()
      val originalInk = StrokeOutline.fromCommands(listOf(
        InkPathCommand(InkPathCommand.MOVE, 20f, 30f),
        InkPathCommand(InkPathCommand.LINE, 90f, 70f),
      ))
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        originalPageId.set(view.documentState.pageMetadata(0).id)
        view.defaultTextColor = "#D00000"
        setPreparedText(preparedPage, TextAnnotationBounds(20.0, 90.0, 180.0, 30.0), "Approved",
          TextAnnotationOptions(untracked = null, font = null, fontSize = null, color = "#D00000",
            direction = null, maxLines = null, alignment = null, verticalAnchor = null))
        document.core.commitInk(DocumentPageContext(view.documentState.generation, view.documentState.activePageId()), originalInk)
        val surface = (view.view as FrameLayout).getChildAt(0) as ViewerCanvas
        preparedPage.undo()
        contentBeforeRotation.set(view.documentState.pageSnapshot(0).content)
        surface.activePointerId = 7
        assertTrue(view.documentState.activeHistoryState().canUndo)
        assertTrue(view.documentState.activeHistoryState().canRedo)
      }

      await(instrumentation, document.rotatePage(0.0, 90.0))
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        val surface = (view.view as FrameLayout).getChildAt(0) as ViewerCanvas
        assertEquals(ViewerCanvas.noPointer, surface.activePointerId)
        assertEquals(originalPageId.get(), view.documentState.pageMetadata(0).id)
        assertEquals(PdfPageDimensions(240.0, 320.0, rotation = 1), view.documentState.pageMetadata(0).dimensions)
        assertTrue(view.documentState.activeHistoryState().canUndo)
        assertTrue(view.documentState.activeHistoryState().canRedo)
        assertEquals(listOf("Approved"), view.documentState.pageSnapshot(0).content
          .mapNotNull { it.textAnnotationOrNull()?.text })
        assertEquals(contentBeforeRotation.get(), view.documentState.pageSnapshot(0).content)
      }
      assertEquals(240.0, preparedPage.getState().width, 0.0)
      assertEquals(320.0, preparedPage.getState().height, 0.0)

      // Reopening working bytes during assembly must retain pending orientation.
      await(instrumentation, document.addPages(DocumentAddPagesOptions(
        tag = null, sources = arrayOf(source.absolutePath), imagePageSize = null,
        targetDpi = null, jpegQuality = null,
      )))
      instrumentation.runOnMainSync {
        assertEquals(originalPageId.get(), viewRef.get().documentState.pageMetadata(0).id)
        assertEquals(1, viewRef.get().documentState.pageMetadata(0).dimensions.rotation)
      }
      await(instrumentation, document.movePage(0.0, 1.0))
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        assertEquals(originalPageId.get(), view.documentState.pageMetadata(1).id)
        assertEquals(contentBeforeRotation.get(), view.documentState.pageSnapshot(1).content)
        assertTrue(view.documentState.activeHistoryState().canRedo)
        ((view.view as FrameLayout).getChildAt(0) as ViewerCanvas).switchPage(0)
      }
      await(instrumentation, document.removePage(0.0))
      instrumentation.runOnMainSync {
        val page = viewRef.get().documentState.pageMetadata(0)
        assertEquals(originalPageId.get(), page.id)
        assertEquals(PdfPageDimensions(240.0, 320.0, 1), page.dimensions)
        assertEquals(PdfPageDimensions(320.0, 240.0, 0), page.sourceDimensions)
        assertEquals(contentBeforeRotation.get(), viewRef.get().documentState.pageSnapshot(0).content)
        assertTrue(viewRef.get().documentState.activeHistoryState().canRedo)
      }
      instrumentation.runOnMainSync { preparedPage.redo() }
      val outputPath = await(instrumentation, document.finalize())
      val visualArtifact = File(checkNotNull(context.getExternalFilesDir(null)), "inksign-rotation-preview.pdf")
      File(java.net.URI(outputPath)).copyTo(visualArtifact, overwrite = true)
      val downloadName = "inksign-rotation-preview-${System.currentTimeMillis()}.pdf"
      val downloadUri = checkNotNull(context.contentResolver.insert(
        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
        ContentValues().apply {
          put(MediaStore.MediaColumns.DISPLAY_NAME, downloadName)
          put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
          put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        },
      ))
      checkNotNull(context.contentResolver.openOutputStream(downloadUri)).use {
        it.write(visualArtifact.readBytes())
      }
      android.util.Log.i("PageRotationInstrumentationTest", "VISUAL_DOWNLOAD=$downloadName")
      val exported = PdfiumRenderSession.open(File(java.net.URI(outputPath)).readBytes())
      try {
        assertEquals(PdfiumPageSize(240.0, 320.0, rotation = 1), exported.pageSize(0))
        val exportedAnalysis = exported.preparePageAnalysis(0)
        assertTrue("Export should retain committed text glyphs: ${glyphText(exportedAnalysis)}",
          glyphText(exportedAnalysis).contains("Approved"))
        val rendered = Bitmap.createBitmap(240, 320, Bitmap.Config.ARGB_8888)
        try {
          assertTrue(exported.renderPageIntoBitmap(0, rendered,
            PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
            PdfiumRect(0.0, 0.0, 240.0, 320.0), flags = pdfiumAndroidDisplayFlags))
          val pixels = redPixelBounds(rendered)
          val expected = PageCoordinates(PdfPageDimensions(240.0, 320.0, rotation = 1))
            .canonicalToDisplay(PageRect(20.0, 90.0, 200.0, 120.0))
          assertTrue("Exported text pixels $pixels should lie within rotated target $expected",
            pixels.left >= expected.left - 2 && pixels.right <= expected.right + 2 &&
              pixels.top >= expected.top - 2 && pixels.bottom <= expected.bottom + 2)
        } finally { rendered.recycle() }
      } finally {
        exported.close()
        File(java.net.URI(outputPath)).delete()
      }

      repeat(3) { await(instrumentation, document.rotatePage(0.0, 90.0)) }
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        assertEquals(PdfPageDimensions(320.0, 240.0, rotation = 0), view.documentState.pageMetadata(0).dimensions)
        assertEquals(4L, view.documentState.pageMetadata(0).geometryRevision)
        assertTrue(view.documentState.pageInfo(view.documentState.activePageIndex).hasInk)
      }
    } catch (error: Throwable) {
      failure.set(error)
    } finally {
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      source.delete()
    }
    failure.get()?.let { throw AssertionError("Rotation behavior failed", it) }
  }

  private fun <T> await(instrumentation: android.app.Instrumentation, promise: Promise<T>): T {
    val settled = CountDownLatch(1)
    val result = AtomicReference<T>()
    val failure = AtomicReference<Throwable>()
    promise.then { result.set(it); settled.countDown() }
      .catch { failure.set(it); settled.countDown() }
    assertTrue("Native operation did not settle", settled.await(30L, TimeUnit.SECONDS))
    failure.get()?.let { throw AssertionError("Native operation rejected", it) }
    return checkNotNull(result.get())
  }

  private fun fieldResolutionOptions() = InputTargetResolutionOptions(font = null,
    fieldName = "Name",
    bounds = null,
    occurrence = TextKeyOccurrence.FIRST,
    fontSize = null,
    color = null,
    direction = TextDirection.LTR,
    maxLines = 2.0,
    alignment = null,
    verticalAnchor = TextVerticalAnchor.BOTTOM,
  )

  private fun sourcePdf(width: Int, height: Int, fieldRules: Boolean = false, importedInk: Boolean = false,
                        savedRotation: Int = 0, oneRule: Boolean = false): ByteArray {
    val content = if (fieldRules) {
      "BT /F1 16 Tf 1 0 0 1 140 ${height - 132} Tm (Name) Tj ET\n" +
        "0 0 0 RG 1 w\n" +
        (if (oneRule) "" else "20 ${height - 132} m 110 ${height - 132} l S\n") +
        "210 ${height - 132} m 280 ${height - 132} l S\n"
    } else "BT /F1 16 Tf 1 0 0 1 24 48 Tm (MARK) Tj ET\n" +
      "0 0 0 RG 2 w 20 30 m 100 30 l S\n"
    val objects = listOf(
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] " +
        "/Rotate $savedRotation /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R " +
        (if (importedInk) "/Annots [6 0 R] " else "") + ">>\nendobj\n",
      "4 0 obj\n<< /Length ${content.toByteArray(Charsets.ISO_8859_1).size} >>\nstream\n$content" +
        "endstream\nendobj\n",
      "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    ) + if (importedInk) listOf(
      "6 0 obj\n<< /Type /Annot /Subtype /Ink /Rect [10 10 80 50] " +
        "/InkList [[20 20 60 40]] /C [0 0 1] /BS << /W 2 >> >>\nendobj\n",
    ) else emptyList()
    val pdf = StringBuilder("%PDF-1.4\n")
    val offsets = objects.map { value ->
      val offset = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
      pdf.append(value)
      offset
    }
    val xref = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
    pdf.append("xref\n0 ${objects.size + 1}\n0000000000 65535 f \n")
    offsets.forEach { pdf.append("%010d 00000 n \n".format(it)) }
    pdf.append("trailer\n<< /Size ${objects.size + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n")
    return pdf.toString().toByteArray(Charsets.ISO_8859_1)
  }

  companion object {
    @JvmStatic
    @BeforeClass
    fun loadNativeLibrary() {
      NativeTestRuntime.initialize()
    }
  }
}
