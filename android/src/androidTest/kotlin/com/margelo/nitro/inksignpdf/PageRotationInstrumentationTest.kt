package com.margelo.nitro.inksignpdf

import android.view.View
import android.view.MotionEvent
import android.graphics.Bitmap
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
import java.util.concurrent.Executors
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
  fun deferredRotationPreservesTextLayoutAndCommitsNewTextUpright() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("rotation-text-", ".pdf", context.cacheDir)
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      source.writeBytes(sourcePdf(width = 320, height = 240))
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context)
        viewRef.set(view)
        val size = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        view.view.measure(size, size)
        view.view.layout(0, 0, 480, 480)
      }
      await(instrumentation, viewRef.get().open(source.absolutePath, null))
      val before = AtomicReference<TextAnnotation>()
      val workingPath = AtomicReference<String>()
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        workingPath.set(view.coordinator.sourcePath)
        view.insertTextAt("Original", TextAnnotationBounds(40.0, 50.0, 180.0, 24.0), null)
        before.set(view.coordinator.pageSnapshot(0).content.single().textAnnotationOrNull())
      }
      await(instrumentation, viewRef.get().rotatePage(90.0))
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        assertEquals(workingPath.get(), view.coordinator.sourcePath)
        assertEquals(PdfPageDimensions(320.0, 240.0, 0), view.coordinator.page(0).sourceDimensions)
        val container = view.view as FrameLayout
        val surface = container.getChildAt(0) as SurfaceView
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
        view.setViewMode(null)
        val edited = checkNotNull(view.coordinator.pageSnapshot(0).content.single().textAnnotationOrNull())
        assertEquals(annotation.flowBounds, edited.flowBounds)
        assertEquals(annotation.layoutPage, edited.layoutPage)

        view.defaultTextColor = "#D00000"
        view.insertTextAt("New text", TextAnnotationBounds(60.0, 160.0, 160.0, 24.0), null)
        val newText = checkNotNull(view.coordinator.pageSnapshot(0).content.last().textAnnotationOrNull())
        assertEquals(PdfPageDimensions(240.0, 320.0, 1), newText.layoutPage)
        val actual = Bitmap.createBitmap(240, 320, Bitmap.Config.ARGB_8888)
        val expected = Bitmap.createBitmap(240, 320, Bitmap.Config.ARGB_8888)
        try {
          val canvas = Canvas(actual)
          canvas.concat(PageCoordinates(view.coordinator.page(0).dimensions)
            .rawToView(PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)).toCanvasMatrix())
          TextRenderLayer.from(listOf(newText)).draw(canvas)
          TextRenderLayer.from(listOf(newText.copy(layoutPage = null))).draw(Canvas(expected))
          assertTrue("Committed rendering must match the upright insertion layout", actual.sameAs(expected))
        } finally {
          actual.recycle()
          expected.recycle()
        }
      }
      val output = await(instrumentation, viewRef.get().finalize())
      try {
        val exported = PdfiumRenderSession.open(File(output).readBytes())
        try {
          assertEquals(PdfiumPageSize(240.0, 320.0, 1), exported.pageSize(0))
          assertTrue(
            "Export should retain the literal text even when lookup finds no usable row geometry",
            exported.textKeyLookup(0, "New text").hasLiteralMatch,
          )
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
      } finally { File(output).delete() }
    } finally {
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      source.delete()
    }
  }

  @Test
  fun committedRotationRejectsPendingInsertionAndFocusResults() {
    assertStaleFieldCommandCancelledByRotation(focus = false)
    assertStaleFieldCommandCancelledByRotation(focus = true)
  }

  @Test
  fun fieldCommandsPairDisplayedRulesAndRejectVerticalRules() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("rotation-fields-", ".pdf", context.cacheDir)
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      source.writeBytes(sourcePdf(300, 400, fieldRules = true))
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context)
        viewRef.set(view)
        val size = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        view.view.measure(size, size)
        view.view.layout(0, 0, 480, 480)
        view.defaultTextColor = "#D00000"
      }
      await(instrumentation, viewRef.get().open(source.absolutePath, null))
      for (angle in listOf(0, 90, 180, 270)) {
        val view = viewRef.get()
        if (angle != 0) await(instrumentation, view.rotatePage(90.0))
        val insertion = view.insertTextByFieldName("OK", "Name", TextInsertionByKeyOptions(
          occurrence = null, direction = TextDirection.LTR, maxLines = 2.0,
          alignment = null, verticalAnchor = TextVerticalAnchor.BOTTOM,
        ))
        if (angle == 90 || angle == 270) {
          for (command in listOf(insertion, view.focusPageByFieldName("Name", FieldFocusOptions(
            occurrence = null, direction = TextDirection.LTR, zoom = 5.0,
            verticalAnchor = FieldFocusVerticalAnchor.BOTTOM, edgeOffset = 8.0, setInkMode = true,
          )))) {
            try {
              await(instrumentation, command)
              throw AssertionError("A vertical rule must not accept a field command")
            } catch (error: AssertionError) {
              assertEquals("text_rule_not_found", (error.cause as? PdfSessionException)?.code)
            }
          }
          instrumentation.runOnMainSync {
            assertTrue(view.coordinator.pageSnapshot(0).content.isEmpty())
            val surface = (view.view as FrameLayout).getChildAt(0) as SurfaceView
            assertTrue(!surface.isEditMode)
          }
          continue
        }
        await(instrumentation, insertion)
        val ruleY = if (angle == 0) 132.0 else 268.0
        val field = PageRect(if (angle == 0) 210.0 else 190.0, 0.0, 280.0, ruleY)
        instrumentation.runOnMainSync {
          val annotation = checkNotNull(view.coordinator.pageSnapshot(0).content.single().textAnnotationOrNull())
          assertEquals(field, annotation.flowBounds)
          assertEquals(angle / 90, annotation.layoutPage?.rotation)
        }
        for (anchor in listOf(FieldFocusVerticalAnchor.TOP, FieldFocusVerticalAnchor.BOTTOM)) {
          await(instrumentation, view.focusPageByFieldName("Name", FieldFocusOptions(
            occurrence = null, direction = TextDirection.LTR, zoom = 5.0,
            verticalAnchor = anchor, edgeOffset = 8.0, setInkMode = false,
          )))
          instrumentation.runOnMainSync {
            val surface = (view.view as FrameLayout).getChildAt(0) as SurfaceView
            val state = surface.currentViewportState()
            val halfHeight = surface.height / (2.0 * state.zoom * context.resources.displayMetrics.density)
            val expected = if (anchor == FieldFocusVerticalAnchor.TOP) ruleY + halfHeight - 8 else ruleY - halfHeight + 8
            assertEquals(expected.coerceIn(halfHeight, 400.0 - halfHeight), state.focus.y, 0.01)
          }
        }
        val output = await(instrumentation, view.finalize())
        try {
          val exported = PdfiumRenderSession.open(File(output).readBytes())
          val bitmap = Bitmap.createBitmap(300, 400, Bitmap.Config.ARGB_8888)
          try {
            assertTrue(exported.textKeyLookup(0, "OK").hasLiteralMatch)
            assertTrue(exported.renderPageIntoBitmap(0, bitmap,
              PdfiumAffineMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
              PdfiumRect(0.0, 0.0, 300.0, 400.0), flags = pdfiumAndroidDisplayFlags))
            val pixels = redPixelBounds(bitmap)
            assertTrue(pixels.width() > pixels.height())
            assertTrue(pixels.left >= field.left - 2 && pixels.right <= field.right + 2 &&
              pixels.top >= field.top - 2 && pixels.bottom <= field.bottom + 2)
          } finally { bitmap.recycle(); exported.close() }
        } finally { File(output).delete() }
        instrumentation.runOnMainSync { view.clear() }
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

  @Test
  fun rotationPreservesHistoryCancelsLiveInputAndPersistsExportedOrientation() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("rotation-source-", ".pdf", context.cacheDir)
    val viewRef = AtomicReference<HybridInkSignView>()
    val failure = AtomicReference<Throwable>()
    try {
      source.writeBytes(sourcePdf(width = 320, height = 240))
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context)
        viewRef.set(view)
        val exactSize = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        view.view.measure(exactSize, exactSize)
        view.view.layout(0, 0, 480, 480)
      }
      await(instrumentation, viewRef.get().open(source.absolutePath, null))

      val originalPageId = AtomicReference<String>()
      val contentBeforeRotation = AtomicReference<List<PageContent>>()
      val originalInk = StrokeOutline.fromCommands(listOf(
        InkPathCommand(InkPathCommand.MOVE, 20f, 30f),
        InkPathCommand(InkPathCommand.LINE, 90f, 70f),
      ))
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        originalPageId.set(view.coordinator.page(0).id)
        view.insertTextAt(
          "Approved",
          TextAnnotationBounds(20.0, 90.0, 180.0, 30.0),
          null,
        )
        view.coordinator.appendActiveInk(originalInk)
        val surface = (view.view as FrameLayout).getChildAt(0) as SurfaceView
        surface.inkRenderer.addCompletedOutline(originalInk)
        view.undo()
        contentBeforeRotation.set(view.coordinator.pageSnapshot(0).content)
        surface.activePointerId = 7
        assertTrue(view.coordinator.activeHistoryState().canUndo)
        assertTrue(view.coordinator.activeHistoryState().canRedo)
      }

      val rotated = await(instrumentation, viewRef.get().rotatePage(90.0))
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        val surface = (view.view as FrameLayout).getChildAt(0) as SurfaceView
        assertEquals(SurfaceView.noPointer, surface.activePointerId)
        assertEquals(originalPageId.get(), view.coordinator.page(0).id)
        assertEquals(PdfPageDimensions(240.0, 320.0, rotation = 1), view.coordinator.page(0).dimensions)
        assertTrue(view.coordinator.activeHistoryState().canUndo)
        assertTrue(view.coordinator.activeHistoryState().canRedo)
        assertEquals(listOf("Approved"), view.coordinator.pageSnapshot(0).content
          .mapNotNull { it.textAnnotationOrNull()?.text })
        assertEquals(contentBeforeRotation.get(), view.coordinator.pageSnapshot(0).content)
      }
      assertEquals(240.0, rotated.width, 0.0)
      assertEquals(320.0, rotated.height, 0.0)

      // Reopening working bytes during assembly must retain pending orientation.
      await(instrumentation, viewRef.get().addPages(AddPagesOptions(
        type = null, sources = arrayOf(source.absolutePath), imagePageSize = null,
        targetDpi = null, jpegQuality = null, activePage = null,
      )))
      instrumentation.runOnMainSync {
        assertEquals(originalPageId.get(), viewRef.get().coordinator.page(0).id)
        assertEquals(1, viewRef.get().coordinator.page(0).dimensions.rotation)
      }
      await(instrumentation, viewRef.get().movePage(1.0))
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        assertEquals(originalPageId.get(), view.coordinator.page(1).id)
        assertEquals(contentBeforeRotation.get(), view.coordinator.pageSnapshot(1).content)
        assertTrue(view.coordinator.activeHistoryState().canRedo)
        ((view.view as FrameLayout).getChildAt(0) as SurfaceView).switchPage(0)
      }
      await(instrumentation, viewRef.get().removePage())
      instrumentation.runOnMainSync {
        val page = viewRef.get().coordinator.page(0)
        assertEquals(originalPageId.get(), page.id)
        assertEquals(PdfPageDimensions(240.0, 320.0, 1), page.dimensions)
        assertEquals(PdfPageDimensions(320.0, 240.0, 0), page.sourceDimensions)
        assertEquals(contentBeforeRotation.get(), viewRef.get().coordinator.pageSnapshot(0).content)
        assertTrue(viewRef.get().coordinator.activeHistoryState().canRedo)
      }
      instrumentation.runOnMainSync { viewRef.get().redo() }
      val outputPath = await(instrumentation, viewRef.get().finalize())
      val visualArtifact = File(checkNotNull(context.getExternalFilesDir(null)), "inksign-rotation-preview.pdf")
      File(outputPath).copyTo(visualArtifact, overwrite = true)
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
      val exported = PdfiumRenderSession.open(File(outputPath).readBytes())
      try {
        assertEquals(PdfiumPageSize(240.0, 320.0, rotation = 1), exported.pageSize(0))
        assertTrue("Export should retain committed text", exported.textKeyLookup(0, "Approved").hasLiteralMatch)
      } finally {
        exported.close()
        File(outputPath).delete()
      }

      repeat(3) { await(instrumentation, viewRef.get().rotatePage(90.0)) }
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        assertEquals(PdfPageDimensions(320.0, 240.0, rotation = 0), view.coordinator.page(0).dimensions)
        assertEquals(4L, view.coordinator.page(0).geometryRevision)
        assertTrue(view.coordinator.activePageHasInk())
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

  private fun assertStaleFieldCommandCancelledByRotation(focus: Boolean) {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("stale-rotation-field-", ".pdf", context.cacheDir)
    val lookupStarted = CountDownLatch(1)
    val releaseLookup = CountDownLatch(1)
    val executor = Executors.newFixedThreadPool(2)
    val worker = PdfSessionWorker(
      opener = PdfSessionOpener { path, generation ->
        BlockingRotationLookupResource(
          PdfSession.open(path, generation),
          lookupStarted,
          releaseLookup,
        )
      },
      executorOverride = executor,
    )
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      source.writeBytes(sourcePdf(width = 320, height = 240))
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context, worker)
        viewRef.set(view)
        val exactSize = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        view.view.measure(exactSize, exactSize)
        view.view.layout(0, 0, 480, 480)
      }
      val opened = await(instrumentation, viewRef.get().open(source.absolutePath, null))
      assertEquals(1.0, opened.pageCount, 0.0)

      val lookupError = AtomicReference<Throwable>()
      val lookupSettled = CountDownLatch(1)
      val command = AtomicReference<Promise<Unit>>()
      instrumentation.runOnMainSync {
        val view = viewRef.get()
        command.set(if (focus) {
          view.focusPageByFieldName("Name", null)
        } else {
          view.insertTextByFieldName("filled", "Name", null)
        })
      }
      command.get().then { lookupSettled.countDown() }
        .catch { error -> lookupError.set(error); lookupSettled.countDown() }
      assertTrue("field command did not reach the blocked worker", lookupStarted.await(10L, TimeUnit.SECONDS))

      await(instrumentation, viewRef.get().rotatePage(90.0))
      instrumentation.runOnMainSync {
        assertEquals(1L, viewRef.get().coordinator.page(0).geometryRevision)
      }
      releaseLookup.countDown()
      assertTrue("stale field command did not settle", lookupSettled.await(10L, TimeUnit.SECONDS))
      assertEquals("operation_cancelled", (lookupError.get() as? PdfSessionException)?.code)
      instrumentation.runOnMainSync {
        assertTrue(viewRef.get().coordinator.pageSnapshot(0).content.isEmpty())
      }
    } finally {
      releaseLookup.countDown()
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      executor.shutdownNow()
      source.delete()
    }
  }

  private class BlockingRotationLookupResource(
    private val delegate: PdfSessionResource,
    private val lookupStarted: CountDownLatch,
    private val releaseLookup: CountDownLatch,
  ) : PdfSessionResource by delegate {
    override fun lookupTextKey(pageIndex: Int, key: String): PdfiumKeyLookupPage {
      val result = PdfiumKeyLookupPage(
        hasLiteralMatch = true,
        matches = listOf(PdfiumTextKeyMatch(80.0, 100.0, 120.0, 112.0, 0.0, 106.0, 12.0)),
        rules = listOf(PdfiumHorizontalSnapCandidate(20.0, 250.0, 118.0)),
      )
      lookupStarted.countDown()
      check(releaseLookup.await(15L, TimeUnit.SECONDS)) { "test did not release the blocked lookup" }
      return result
    }
  }

  private fun sourcePdf(width: Int, height: Int, fieldRules: Boolean = false): ByteArray {
    val content = if (fieldRules) {
      "BT /F1 16 Tf 1 0 0 1 140 ${height - 132} Tm (Name) Tj ET\n" +
        "0 0 0 RG 1 w 20 ${height - 132} m 110 ${height - 132} l S\n" +
        "210 ${height - 132} m 280 ${height - 132} l S\n"
    } else "BT /F1 16 Tf 1 0 0 1 24 48 Tm (MARK) Tj ET\n" +
      "0 0 0 RG 2 w 20 30 m 100 30 l S\n"
    val objects = listOf(
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] " +
        "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n",
      "4 0 obj\n<< /Length ${content.toByteArray(Charsets.ISO_8859_1).size} >>\nstream\n$content" +
        "endstream\nendobj\n",
      "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    )
    val pdf = StringBuilder("%PDF-1.4\n")
    val offsets = objects.map { value ->
      val offset = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
      pdf.append(value)
      offset
    }
    val xref = pdf.toString().toByteArray(Charsets.ISO_8859_1).size
    pdf.append("xref\n0 6\n0000000000 65535 f \n")
    offsets.forEach { pdf.append("%010d 00000 n \n".format(it)) }
    pdf.append("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n")
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
