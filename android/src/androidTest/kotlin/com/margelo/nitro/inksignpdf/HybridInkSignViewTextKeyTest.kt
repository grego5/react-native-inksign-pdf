package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.view.View
import android.widget.FrameLayout
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.margelo.nitro.core.Promise
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class HybridInkSignViewTextKeyTest {
  @Test
  fun keyInsertionCompletesOnCapturedPageAfterNavigation() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val source = File.createTempFile("stale-key-lookup-", ".pdf", context.cacheDir)
      .apply { writeText("controlled test source") }
    val lookupStarted = CountDownLatch(1)
    val releaseLookup = CountDownLatch(1)
    val resourceRef = AtomicReference<BlockingKeyLookupResource>()
    val worker = PdfSessionWorker(
      opener = PdfSessionOpener { path, generation ->
        BlockingKeyLookupResource(
          PdfSessionInfo(
            sourcePath = path,
            pages = listOf(PdfPageDimensions(300.0, 300.0), PdfPageDimensions(300.0, 300.0)),
            generation = generation,
          ),
          lookupStarted,
          releaseLookup,
        ).also(resourceRef::set)
      },
    )
    val viewRef = AtomicReference<HybridInkSignView>()
    val surfaceRef = AtomicReference<SurfaceView>()

    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context, worker)
        viewRef.set(view)
        val host = view.view
        val exactSize = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        host.measure(exactSize, exactSize)
        host.layout(0, 0, 300, 300)
        surfaceRef.set((host as FrameLayout).getChildAt(0) as SurfaceView)
      }
      awaitOpen(instrumentation, viewRef.get(), source.absolutePath)

      val textContentChanges = AtomicInteger()
      instrumentation.runOnMainSync {
        val surface = surfaceRef.get()
        val previousCallback = surface.onTextContentChanged
        surface.onTextContentChanged = {
          textContentChanges.incrementAndGet()
          previousCallback?.invoke()
        }
      }

      instrumentation.runOnMainSync {
        val view = viewRef.get()
        val surface = surfaceRef.get()
        view.addTextAnnotation("page zero", TextAnnotationBounds(20.0, 20.0, 120.0, 30.0), null)
        surface.switchPage(1)
        view.addTextAnnotation("page one", TextAnnotationBounds(20.0, 20.0, 120.0, 30.0), null)
        surface.switchPage(0)
      }

      val before = AtomicReference<List<PageHistoryState>>()
      instrumentation.runOnMainSync {
        before.set(pageHistoryStates(viewRef.get()))
      }

      val settled = CountDownLatch(1)
      val failure = AtomicReference<Throwable>()
      val insertion = AtomicReference<Promise<Unit>>()
      instrumentation.runOnMainSync {
        insertion.set(viewRef.get().insertTextByFieldName("new value", "Missing", null))
      }
      insertion.get().then { settled.countDown() }
        .catch { error -> failure.set(error); settled.countDown() }

      assertTrue("production key lookup did not reach the worker", lookupStarted.await(10L, TimeUnit.SECONDS))
      instrumentation.runOnMainSync { surfaceRef.get().switchPage(1) }
      val changesBeforeCommit = AtomicInteger()
      instrumentation.runOnMainSync { changesBeforeCommit.set(textContentChanges.get()) }
      releaseLookup.countDown()
      assertTrue("insertTextByFieldName did not settle", settled.await(10L, TimeUnit.SECONDS))
      assertTrue("key insertion failed after navigation: ${failure.get()}", failure.get() == null)
      assertEquals("an inactive-page commit must not sync the active overlay",
        changesBeforeCommit.get(), textContentChanges.get())

      val after = AtomicReference<List<PageHistoryState>>()
      instrumentation.runOnMainSync {
        after.set(pageHistoryStates(viewRef.get()))
      }
      assertEquals(before.get()[0].content.size + 1, after.get()[0].content.size)
      assertEquals(
        listOf("page zero", "new value"),
        after.get()[0].content.mapNotNull { it.textAnnotationOrNull()?.text },
      )
      assertEquals(
        listOf("page one"),
        after.get()[1].content.mapNotNull { it.textAnnotationOrNull()?.text },
      )
      assertTrue("the controlled PDF session was not opened", resourceRef.get() != null)
    } finally {
      releaseLookup.countDown()
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      source.delete()
    }
  }

  @Test
  fun replacementCancelsPendingProductionKeyLookupAndInstallsOnlyNewDocument() {
    NativeTestRuntime.initialize()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val sourceA = File.createTempFile("replace-key-lookup-a-", ".pdf", context.cacheDir)
      .apply { writeText("controlled source A") }
    val sourceB = File.createTempFile("replace-key-lookup-b-", ".pdf", context.cacheDir)
      .apply { writeText("controlled source B") }
    val lookupStarted = CountDownLatch(1)
    val releaseLookup = CountDownLatch(1)
    val worker = PdfSessionWorker(
      opener = PdfSessionOpener { path, generation ->
        BlockingKeyLookupResource(
          PdfSessionInfo(
            sourcePath = path,
            pages = listOf(PdfPageDimensions(300.0, 300.0)),
            generation = generation,
          ),
          lookupStarted,
          releaseLookup,
        )
      },
    )
    val viewRef = AtomicReference<HybridInkSignView>()
    try {
      instrumentation.runOnMainSync {
        val view = HybridInkSignView(context, worker)
        viewRef.set(view)
        val exactSize = View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY)
        view.view.measure(exactSize, exactSize)
        view.view.layout(0, 0, 300, 300)
      }
      awaitOpen(instrumentation, viewRef.get(), sourceA.absolutePath, expectedPageCount = 1.0)
      val originalPath = viewRef.get().coordinator.sourcePath

      val lookupSettled = CountDownLatch(1)
      val rejectionCount = AtomicInteger()
      val lookupError = AtomicReference<Throwable>()
      val lookup = AtomicReference<Promise<Unit>>()
      instrumentation.runOnMainSync {
        lookup.set(viewRef.get().insertTextByFieldName("value", "Missing", null))
      }
      lookup.get().then { lookupSettled.countDown() }
        .catch { error -> lookupError.set(error); rejectionCount.incrementAndGet(); lookupSettled.countDown() }
      assertTrue("production key lookup did not reach the worker", lookupStarted.await(10L, TimeUnit.SECONDS))

      val openSettled = CountDownLatch(1)
      val replacementInfo = AtomicReference<PageInfo>()
      val replacementError = AtomicReference<Throwable>()
      val replacement = AtomicReference<Promise<PageInfo>>()
      instrumentation.runOnMainSync {
        replacement.set(viewRef.get().open(sourceB.absolutePath, null))
        assertTrue("replacement did not clear the active document", !viewRef.get().coordinator.hasDocument)
      }
      replacement.get().then { info -> replacementInfo.set(info); openSettled.countDown() }
        .catch { error -> replacementError.set(error); openSettled.countDown() }

      assertTrue("stale key lookup did not cancel promptly", lookupSettled.await(5L, TimeUnit.SECONDS))
      assertEquals("operation_cancelled", (lookupError.get() as? PdfSessionException)?.code)
      assertEquals(1, rejectionCount.get())
      releaseLookup.countDown()
      assertTrue("replacement open did not settle", openSettled.await(10L, TimeUnit.SECONDS))
      replacementError.get()?.let { throw AssertionError("replacement open failed", it) }
      assertEquals(1.0, replacementInfo.get().pageCount, 0.0)
      instrumentation.runOnMainSync {
        assertTrue(viewRef.get().coordinator.sourcePath != originalPath)
        assertTrue(viewRef.get().coordinator.pageSnapshot(0).content.isEmpty())
      }
    } finally {
      releaseLookup.countDown()
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      sourceA.delete()
      sourceB.delete()
    }
  }

  private fun pageHistoryStates(view: HybridInkSignView): List<PageHistoryState> =
    (0..1).map { pageIndex ->
      PageHistoryState(
        content = view.coordinator.pageSnapshot(pageIndex).content,
        revision = view.coordinator.pageHistoryRevision(pageIndex),
      )
    }

  private fun awaitOpen(
    instrumentation: android.app.Instrumentation,
    view: HybridInkSignView,
    sourcePath: String,
    expectedPageCount: Double = 2.0,
  ) {
    val settled = CountDownLatch(1)
    val result = AtomicReference<PageInfo>()
    val failure = AtomicReference<Throwable>()
    val open = AtomicReference<Promise<PageInfo>>()
    instrumentation.runOnMainSync { open.set(view.open(sourcePath, null)) }
    open.get().then { pageInfo -> result.set(pageInfo); settled.countDown() }
      .catch { error -> failure.set(error); settled.countDown() }
    assertTrue("open did not settle", settled.await(10L, TimeUnit.SECONDS))
    failure.get()?.let { throw AssertionError("controlled document open failed", it) }
    assertEquals(expectedPageCount, result.get().pageCount, 0.0)
  }

  private data class PageHistoryState(
    val content: List<PageContent>,
    val revision: Long,
  )

  private class BlockingKeyLookupResource(
    override val info: PdfSessionInfo,
    private val lookupStarted: CountDownLatch,
    private val releaseLookup: CountDownLatch,
  ) : PdfSessionResource {
    override fun lookupTextKey(pageIndex: Int, key: String): PdfiumKeyLookupPage {
      lookupStarted.countDown()
      check(releaseLookup.await(10L, TimeUnit.SECONDS)) { "test did not release the blocked lookup" }
      return PdfiumKeyLookupPage(
        hasLiteralMatch = true,
        matches = listOf(PdfiumTextKeyMatch(80.0, 100.0, 120.0, 112.0, 0.0, 106.0, 12.0)),
        rules = listOf(PdfiumHorizontalSnapCandidate(20.0, 250.0, 118.0)),
      )
    }

    override fun renderTiles(requests: List<PdfTileRequest>, beforeEach: () -> Unit): List<PdfTile> {
      requests.forEach { beforeEach() }
      return emptyList()
    }

    override fun renderPreview(request: PdfTileRequest, beforeRender: () -> Unit): PdfTile {
      beforeRender()
      return PdfTile(
        request,
        Bitmap.createBitmap(request.widthPx.coerceAtLeast(1), request.heightPx.coerceAtLeast(1),
          Bitmap.Config.ARGB_8888),
      )
    }

    override fun close() = Unit
  }
}
