package com.margelo.nitro.inksignpdf

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.activity.result.ActivityResult
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PageInputCoordinatorInstrumentationTest {
  @Test
  fun pickerImportsMixedSourcesInOrderAndExplicitSourcesBypassPresentation() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val png = testPng()
    val pdf = testPdf(context, png)
    val pdfUri = Uri.parse("content://picker/ordered.pdf")
    val pngUri = Uri.parse("content://picker/ordered.png")
    val sources = mapOf(pdfUri.toString() to pdf, pngUri.toString() to png)
    val registrar = ControlledRegistrar()
    val artifacts = CacheArtifactPolicy.initialize(context)
    val input = PageInputCoordinator(context, artifacts,
      sourceOpener = { uri -> sources[uri.toString()]?.let(::ByteArrayInputStream) },
      pickerRegistrar = registrar)
    val core = DocumentCore(context, recordHistory = true, exportOwnership = ExportOwnership.CALLER,
      inputCoordinator = input)
    val document = HybridInkSignDocument(core)

    try {
      val opening = promise(instrumentation) {
        document.addPages(DocumentAddPagesOptions(type = null,
          tag = "picked", imagePageSize = ImagePageSize(144.0, 72.0), targetDpi = null,
          jpegQuality = null, sources = null))
      }
      val openRequest = registrar.awaitLaunch()
      assertEquals(Intent.ACTION_OPEN_DOCUMENT, openRequest.intent.action)
      assertEquals("*/*", openRequest.intent.type)
      assertTrue(openRequest.intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
      assertArrayEquals(arrayOf("application/pdf", "image/*"),
        openRequest.intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
      onMain(instrumentation) { registrar.deliver(listOf(pdfUri, pngUri)) }
      await(opening)

      assertEquals(2, onMain(instrumentation) { core.state.pageCount })
      assertPage(instrumentation, core, 0, 80.0, 40.0, "picked")
      assertPage(instrumentation, core, 1, 144.0, 72.0, "picked")
      assertEquals(2, onMain(instrumentation) { core.getPageIdsByTag("picked").size })
      assertNoStagedInputs(artifacts)

      val appending = deferred(instrumentation, core) {
        core.addPages(DocumentAddPagesOptions(type = null, tag = "appended", sources = null,
          imagePageSize = ImagePageSize(120.0, 60.0), targetDpi = 72.0,
          jpegQuality = 0.4), PdfPageDimensions(120.0, 60.0))
      }
      val appendRequest = registrar.awaitLaunch()
      onMain(instrumentation) { registrar.deliver(listOf(pngUri, pdfUri)) }
      assertEquals(2, await(appending))
      assertEquals(4, onMain(instrumentation) { core.state.pageCount })
      assertPage(instrumentation, core, 2, 120.0, 60.0, "appended")
      assertPage(instrumentation, core, 3, 80.0, 40.0, "appended")
      assertEquals(2, onMain(instrumentation) { core.getPageIdsByTag("appended").size })
      assertEquals(2, registrar.registerCount)
      assertEquals(Intent.ACTION_OPEN_DOCUMENT, appendRequest.intent.action)

      val callsBeforeDirect = registrar.registerCount
      val direct = promise(instrumentation) {
        document.addPages(DocumentAddPagesOptions(type = PageInputType.PDF, tag = "direct",
          sources = arrayOf(pdfUri.toString()), imagePageSize = null, targetDpi = null,
          jpegQuality = null))
      }
      assertEquals(1.0, await(direct).addedPageCount, 0.0)
      assertEquals(callsBeforeDirect, registrar.registerCount)
      assertEquals(5, onMain(instrumentation) { core.state.pageCount })
      assertEquals(1, onMain(instrumentation) { core.getPageIdsByTag("direct").size })
      assertTrue("Headless import must not claim a viewer", onMain(instrumentation) {
        core.claimViewer("independence-check").let { core.releaseViewer("independence-check"); true }
      })
      assertArrayEquals(pdf, sources.getValue(pdfUri.toString()))
      assertArrayEquals(png, sources.getValue(pngUri.toString()))
      assertNoStagedInputs(artifacts)
    } finally {
      close(instrumentation, core)
    }
  }

  @Test
  fun typeMismatchAndUnreadableSourceRejectAtomicallyAndCleanStaging() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val png = testPng()
    val pdf = testPdf(context, png)
    val pdfUri = Uri.parse("content://picker/valid.pdf")
    val pngUri = Uri.parse("content://picker/wrong-type.png")
    val missingUri = Uri.parse("content://picker/missing.pdf")
    val sources = mapOf(pdfUri.toString() to pdf, pngUri.toString() to png)
    val artifacts = CacheArtifactPolicy.initialize(context)
    val input = PageInputCoordinator(context, artifacts,
      sourceOpener = { uri -> sources[uri.toString()]?.let(::ByteArrayInputStream) })
    val core = DocumentCore(context, recordHistory = true, exportOwnership = ExportOwnership.CALLER,
      inputCoordinator = input)
    try {
      await(promise(instrumentation) { HybridInkSignDocument(core).initializeSource(pdfUri.toString(), initialOptions()) })
      val events = ArrayList<DocumentChange>()
      val observer = onMain(instrumentation) { core.observe(events::add) }
      val count = onMain(instrumentation) { core.state.pageCount }
      val mismatch = promise(instrumentation) {
        HybridInkSignDocument(core).addPages(DocumentAddPagesOptions(type = PageInputType.PDF,
          tag = "must-not-publish", sources = arrayOf(pdfUri.toString(), pngUri.toString()),
          imagePageSize = null, targetDpi = null, jpegQuality = null))
      }
      assertError("unsupported_content", mismatch)
      val unreadable = promise(instrumentation) {
        HybridInkSignDocument(core).addPages(DocumentAddPagesOptions(type = null, tag = "must-not-publish",
          sources = arrayOf(pdfUri.toString(), missingUri.toString()), imagePageSize = null,
          targetDpi = null, jpegQuality = null))
      }
      assertError("unreadable_source", unreadable)
      assertEquals(count, onMain(instrumentation) { core.state.pageCount })
      assertTrue(onMain(instrumentation) { core.getPageIdsByTag("must-not-publish").isEmpty() })
      assertFalse(events.any { it == DocumentChange.StructuralWriteStarted || it == DocumentChange.Pages })
      assertArrayEquals(pdf, sources.getValue(pdfUri.toString()))
      assertArrayEquals(png, sources.getValue(pngUri.toString()))
      assertNoStagedInputs(artifacts)
      onMain(instrumentation) { observer.close() }
    } finally {
      close(instrumentation, core)
    }
  }

  @Test
  fun cancelledPickerAppendPreservesDraftHistoryAndIgnoresLateResult() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val png = testPng()
    val pdf = testPdf(context, png)
    val source = File(context.cacheDir, "picker-cancel-${System.nanoTime()}.pdf").apply { writeBytes(pdf) }
    val registrar = ControlledRegistrar()
    val artifacts = CacheArtifactPolicy.initialize(context)
    val input = PageInputCoordinator(context, artifacts, pickerRegistrar = registrar)
    val core = DocumentCore(context, recordHistory = true, exportOwnership = ExportOwnership.CALLER,
      inputCoordinator = input)
    try {
      await(promise(instrumentation) { HybridInkSignDocument(core).initializeSource(source.absolutePath, initialOptions()) })
      val page = await(deferred(instrumentation, core) { core.getPage(0.0) })
      val committed = onMain(instrumentation) {
        core.text.insert(page, TextAnnotationBounds(5.0, 5.0, 35.0, 20.0), "committed")
      }
      val edit = onMain(instrumentation) { core.beginTextEdit(page, committed.id) }
      onMain(instrumentation) { core.updateTextEdit(edit, committed.copy(text = "draft")) }
      val revision = onMain(instrumentation) { core.state.pageHistoryRevision(0) }
      val events = ArrayList<DocumentChange>()
      val observer = onMain(instrumentation) { core.observe(events::add) }
      val settled = AtomicInteger()

      val append = deferred(instrumentation, core) {
        core.addPages(DocumentAddPagesOptions(type = null, tag = "cancelled", sources = null,
          imagePageSize = null, targetDpi = null, jpegQuality = null), PdfPageDimensions(80.0, 40.0))
      }
      val request = registrar.awaitLaunch()
      append.invokeOnCompletion { settled.incrementAndGet() }
      onMain(instrumentation) { registrar.cancel() }
      assertEquals(0, await(append))
      onMain(instrumentation) { registrar.deliverLate(listOf(Uri.parse("file:///late.pdf"))) }
      assertEquals(1, settled.get())
      assertTrue(onMain(instrumentation) { edit.active && core.activeTextEdit === edit })
      assertEquals("draft", onMain(instrumentation) { core.text.getValue(page, committed.id.toDouble()) })
      assertEquals(revision, onMain(instrumentation) { core.state.pageHistoryRevision(0) })
      assertEquals(1, onMain(instrumentation) { core.state.pageCount })
      assertTrue(events.none { it == DocumentChange.StructuralWriteStarted || it == DocumentChange.Pages || it is DocumentChange.EditEnded })
      assertTrue(request.handle.unregisterCount.get() > 0)
      onMain(instrumentation) { observer.close() }
    } finally {
      source.delete()
      close(instrumentation, core)
    }
  }

  @Test
  fun closeCancelsWaitingAndQueuedPickersButDrainsInitialSources() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val png = testPng()
    val pdf = testPdf(context, png)
    val uri = Uri.parse("content://picker/close.pdf")
    val registrar = ControlledRegistrar()
    val artifacts = CacheArtifactPolicy.initialize(context)
    val input = PageInputCoordinator(context, artifacts,
      sourceOpener = { source -> if (source == uri) ByteArrayInputStream(pdf) else null },
      pickerRegistrar = registrar)
    val core = DocumentCore(context, recordHistory = true, exportOwnership = ExportOwnership.CALLER,
      inputCoordinator = input)
    try {
      val first = deferred(instrumentation, core) {
        core.addPages(null, PdfPageDimensions(80.0, 40.0))
      }
      registrar.awaitLaunch()
      val queued = deferred(instrumentation, core) {
        core.addPages(null, PdfPageDimensions(80.0, 40.0))
      }
      val closing = onMain(instrumentation) { core.close() }
      assertError("operation_cancelled", first)
      assertError("operation_cancelled", queued)
      await(closing)
      onMain(instrumentation) { registrar.deliverLate(listOf(uri)) }
      assertEquals(1, registrar.registerCount)
      assertNoStagedInputs(artifacts)
    } finally {
      close(instrumentation, core)
    }

    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val directUri = Uri.parse("content://direct/drain.pdf")
    val drainInput = PageInputCoordinator(context, artifacts, sourceOpener = {
      object : InputStream() {
        private val delegate = ByteArrayInputStream(pdf)
        private var gated = false
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
          if (!gated) { gated = true; entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
          return delegate.read(buffer, offset, length)
        }
        override fun read(): Int = delegate.read()
      }
    })
    val directCore = DocumentCore(context, recordHistory = true, exportOwnership = ExportOwnership.CALLER,
      inputCoordinator = drainInput)
    try {
      val loading = onMain(instrumentation) {
        directCore.initialize(initialOptions().copy(sources = arrayOf(directUri.toString())))
      }
      assertTrue("Direct source copy did not reach the controlled read", entered.await(10, TimeUnit.SECONDS))
      val closing = onMain(instrumentation) { directCore.close() }
      assertFalse("Close must wait for admitted direct-source import", closing.isCompleted)
      release.countDown()
      assertEquals(1, await(loading))
      await(closing)
    } finally {
      release.countDown()
      close(instrumentation, directCore)
    }
  }

  @Test
  fun pickerLeaseIsGlobalAndMissingActivityFailsWithoutOpeningPicker() {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val artifacts = CacheArtifactPolicy.initialize(context)
    val firstRegistrar = ControlledRegistrar()
    val first = PageInputCoordinator(context, artifacts, pickerRegistrar = firstRegistrar)
    val secondRegistrar = ControlledRegistrar()
    val second = PageInputCoordinator(context, artifacts, pickerRegistrar = secondRegistrar)
    val firstCore = DocumentCore(context, recordHistory = true, exportOwnership = ExportOwnership.CALLER,
      inputCoordinator = first)
    val secondCore = DocumentCore(context, recordHistory = true, exportOwnership = ExportOwnership.CALLER,
      inputCoordinator = second)
    try {
      val firstRequest = deferred(instrumentation, firstCore) { first.stage(null) }
      firstRegistrar.awaitLaunch()
      val rejected = deferred(instrumentation, secondCore) { second.stage(null) }
      assertError("operation_in_progress", rejected)
      assertEquals(0, secondRegistrar.registerCount)
      onMain(instrumentation) { firstRegistrar.cancel() }
      assertTrue(await(firstRequest).isEmpty())
      onMain(instrumentation) { firstRegistrar.deliverLate(emptyList()) }
      assertEquals(1, firstRegistrar.registerCount)
    } finally {
      close(instrumentation, firstCore)
      close(instrumentation, secondCore)
    }

    val noPresenter = PageInputCoordinator(context, artifacts)
    val noPresenterCore = DocumentCore(context, recordHistory = true, exportOwnership = ExportOwnership.CALLER,
      inputCoordinator = noPresenter)
    try {
      val failed = deferred(instrumentation, noPresenterCore) { noPresenter.stage(null) }
      assertError("missing_presenter", failed)
    } finally {
      close(instrumentation, noPresenterCore)
    }
  }

  private fun initialOptions() = DocumentOptions(type = PageInputType.PDF, recordHistory = null,
    tag = null, imagePageSize = null, targetDpi = null, jpegQuality = null, androidFallbackFont = null, sources = null)

  private fun testPng(): ByteArray = ByteArrayOutputStream().use { output ->
    val bitmap = Bitmap.createBitmap(3, 2, Bitmap.Config.ARGB_8888)
    try {
      bitmap.eraseColor(android.graphics.Color.GREEN)
      check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
    } finally { bitmap.recycle() }
    output.toByteArray()
  }

  private fun testPdf(context: Context, pngBytes: ByteArray): ByteArray {
    val image = File(context.cacheDir, "picker-source-${System.nanoTime()}.png").apply { writeBytes(pngBytes) }
    val pdf = File(context.cacheDir, "picker-seed-${System.nanoTime()}.pdf")
    try {
      val encoded = ImagePageEncoder.encode(image, PdfPageDimensions(80.0, 40.0))
      val pages = PdfiumPageAssembler.assemble(input = null,
        request = PdfiumAssemblyRequest(PdfiumAssemblyOperation.CREATE, appendInputs = listOf(encoded)),
        scratch = pdf)
      assertEquals(1, pages.size)
      return pdf.readBytes()
    } finally { image.delete(); pdf.delete() }
  }

  private fun assertPage(instrumentation: android.app.Instrumentation, core: DocumentCore, index: Int,
    width: Double, height: Double, tag: String) {
    val page = onMain(instrumentation) { core.state.pageMetadata(index) }
    assertEquals(width, page.dimensions.width, 0.0001)
    assertEquals(height, page.dimensions.height, 0.0001)
    assertEquals(tag, page.tag)
  }

  private fun assertNoStagedInputs(artifacts: CacheArtifactPolicy) {
    assertTrue(artifacts.root.listFiles().orEmpty().none { it.name.startsWith(".input-") })
  }

  private fun <T> onMain(instrumentation: android.app.Instrumentation, action: () -> T): T {
    val result = AtomicReference<T>()
    instrumentation.runOnMainSync { result.set(action()) }
    return checkNotNull(result.get())
  }

  private fun <T> deferred(instrumentation: android.app.Instrumentation, core: DocumentCore,
    action: suspend () -> T): Deferred<T> {
    val result = AtomicReference<Deferred<T>>()
    instrumentation.runOnMainSync { result.set(core.submit(action)) }
    return checkNotNull(result.get())
  }

  private fun <T> await(deferred: Deferred<T>): T = runBlocking {
    withTimeout(TimeUnit.SECONDS.toMillis(30)) { deferred.await() }
  }

  private fun <T> promise(instrumentation: android.app.Instrumentation, action: () -> com.margelo.nitro.core.Promise<T>): com.margelo.nitro.core.Promise<T> {
    val result = AtomicReference<com.margelo.nitro.core.Promise<T>>()
    instrumentation.runOnMainSync { result.set(action()) }
    return checkNotNull(result.get())
  }

  private fun <T> await(promise: com.margelo.nitro.core.Promise<T>): T {
    val latch = CountDownLatch(1)
    val value = AtomicReference<T>()
    val failure = AtomicReference<Throwable>()
    promise.then { value.set(it); latch.countDown() }.catch { failure.set(it); latch.countDown() }
    assertTrue("Native command did not settle", latch.await(30, TimeUnit.SECONDS))
    failure.get()?.let { throw AssertionError("Native command failed", it) }
    return checkNotNull(value.get())
  }

  private fun assertError(code: String, deferred: Deferred<*>) {
    val error = try { await(deferred); null } catch (failure: Throwable) { failure }
    assertTrue("Expected $code, got $error", error?.message?.contains(code) == true || error?.cause?.message?.contains(code) == true)
  }

  private fun assertError(code: String, promise: com.margelo.nitro.core.Promise<*>) {
    val error = try { await(promise); null } catch (failure: Throwable) { failure }
    assertTrue("Expected $code, got $error", error?.message?.contains(code) == true || error?.cause?.message?.contains(code) == true)
  }

  private fun close(instrumentation: android.app.Instrumentation, core: DocumentCore) {
    try { await(onMain(instrumentation) { core.close(cancelPending = true) }) } catch (_: Throwable) { }
  }

  private class ControlledRegistrar : PagePickerRegistrar {
    data class Launch(val intent: Intent, val handle: ControlledHandle)
    private val launches = java.util.concurrent.LinkedBlockingQueue<Launch>()
    private val callbacks = java.util.concurrent.CopyOnWriteArrayList<(ActivityResult) -> Unit>()
    private val requests = AtomicInteger()
    val registerCount: Int get() = requests.get()

    override fun register(token: Any, callback: (ActivityResult) -> Unit): PagePickerHandle {
      requests.incrementAndGet()
      callbacks += callback
      return ControlledHandle().also { handle -> handle.onLaunch = { intent -> launches += Launch(intent, handle) } }
    }

    fun awaitLaunch(): Launch {
      return checkNotNull(launches.poll(10, TimeUnit.SECONDS)) { "Picker was not launched" }
    }

    fun deliver(uris: List<Uri>) = deliverResult(Activity.RESULT_OK, uris)
    fun cancel() = deliverResult(Activity.RESULT_CANCELED, null)
    fun deliverLate(uris: List<Uri>) = deliverResult(Activity.RESULT_OK, uris)

    private fun deliverResult(code: Int, uris: List<Uri>?) {
      val callback = callbacks.lastOrNull() ?: error("No registered picker callback")
      val intent = if (uris == null) null else Intent().apply {
        if (uris.isNotEmpty()) {
          val clip = ClipData("picked", arrayOf("application/octet-stream"), ClipData.Item(uris.first()))
          uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
          setClipData(clip)
        }
      }
      callback(ActivityResult(code, intent))
    }

    class ControlledHandle : PagePickerHandle {
      val unregisterCount = AtomicInteger()
      lateinit var onLaunch: (Intent) -> Unit
      override fun launch(intent: Intent) { onLaunch(intent) }
      override fun unregister() { unregisterCount.incrementAndGet() }
    }
  }

  companion object {
    @JvmStatic
    @BeforeClass
    fun loadNativeLibrary() { NativeTestRuntime.initialize() }
  }
}
