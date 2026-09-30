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
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class HybridInkSignViewTextKeyTest {
  @Test
  fun staleProductionKeyLookupAfterPageSwitchDoesNotChangeEitherPage() {
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
        insertion.set(viewRef.get().insertTextByKey("new value", "Missing", null))
      }
      insertion.get().then { settled.countDown() }
        .catch { error -> failure.set(error); settled.countDown() }

      assertTrue("production key lookup did not reach the worker", lookupStarted.await(10L, TimeUnit.SECONDS))
      instrumentation.runOnMainSync { surfaceRef.get().switchPage(1) }
      releaseLookup.countDown()
      assertTrue("insertTextByKey did not settle", settled.await(10L, TimeUnit.SECONDS))
      assertEquals("operation_cancelled", (failure.get() as? PdfSessionException)?.code)

      val after = AtomicReference<List<PageHistoryState>>()
      instrumentation.runOnMainSync {
        after.set(pageHistoryStates(viewRef.get()))
      }
      assertEquals(before.get(), after.get())
      assertEquals("page zero", after.get()[0].content.single().textAnnotationOrNull()?.text)
      assertEquals("page one", after.get()[1].content.single().textAnnotationOrNull()?.text)
      assertTrue("the controlled PDF session was not opened", resourceRef.get() != null)
    } finally {
      releaseLookup.countDown()
      instrumentation.runOnMainSync { viewRef.get()?.onDropView() }
      source.delete()
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
    assertEquals(2.0, result.get().pageCount, 0.0)
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
      return PdfiumKeyLookupPage(false, emptyList(), emptyList())
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
