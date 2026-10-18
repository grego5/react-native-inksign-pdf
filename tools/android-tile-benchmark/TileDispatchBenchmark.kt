package com.margelo.nitro.inksignpdf

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import android.view.View
import android.view.WindowManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.Collections
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Included only by test-android.ps1 -TileBenchmark, never by normal test runs. */
class TileBenchmarkActivity : Activity() {
  lateinit var drawing: View
  var drawFrame: ((Canvas) -> Unit)? = null
  override fun onCreate(state: Bundle?) {
    super.onCreate(state)
    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    setShowWhenLocked(true)
    setTurnScreenOn(true)
    drawing = object : View(this) {
      override fun onDraw(canvas: Canvas) { drawFrame?.invoke(canvas) }
    }
    setContentView(drawing)
  }
}

@RunWith(AndroidJUnit4::class)
class TileDispatchBenchmark {
  private val instrumentation = InstrumentationRegistry.getInstrumentation()
  private val context = instrumentation.targetContext
  private val results = JSONArray()
  private val memoryResults = JSONArray()

  @Test
  fun measureRealPdfiumDispatch() {
    NativeTestRuntime.initialize()
    assertTrue("Measurement APK must not be debuggable",
      context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0)
    assertTrue("Measurement must use the release library", !BuildConfig.DEBUG)
    val intent = Intent(context, TileBenchmarkActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    val activity = instrumentation.startActivitySync(intent) as TileBenchmarkActivity
    try {
      instrumentation.waitForIdleSync()
      assertTrue("Activity needs a visible viewport", activity.drawing.width > 0 && activity.drawing.height > 0)
      for (image in listOf(false, true)) {
        val source = fixture(image)
        try {
          // First session warms class loading/JIT; it is reported separately.
          for (iteration in 0..5) runCase(activity, source, image, iteration)
        } finally { source.delete() }
      }
      val report = JSONObject().put("device", Build.MODEL).put("sdk", Build.VERSION.SDK_INT)
        .put("fingerprint", Build.FINGERPRINT).put("build", "release, non-debuggable")
        .put("viewportWidth", activity.drawing.width).put("viewportHeight", activity.drawing.height)
        .put("density", context.resources.displayMetrics.density).put("samples", results)
        .put("memorySamples", memoryResults)
        .put("notes", "Generated vector and image PDFs; no base raster, ink, or React. Times are CPU draw submission, not physical presentation. Warmup iteration 0 is excluded from comparisons. Cold means a fresh session and tile cache, not cold OS filesystem cache.")
      val name = "inksign-tile-dispatch-${System.currentTimeMillis()}.json"
      val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,
        ContentValues().apply {
          put(MediaStore.MediaColumns.DISPLAY_NAME, name)
          put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
          put(MediaStore.MediaColumns.IS_PENDING, 1)
        }) ?: error("Cannot create measurement report")
      context.contentResolver.openOutputStream(uri)!!.bufferedWriter().use { it.write(report.toString(2)) }
      context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
      Log.i("InkSignTileBenchmark", "REPORT /sdcard/Download/$name")
    } finally {
      instrumentation.runOnMainSync { activity.drawFrame = null; activity.finish() }
    }
  }

  private fun runCase(activity: TileBenchmarkActivity, source: File, image: Boolean, iteration: Int) {
    val memoryBefore = memorySnapshot()
    var memoryAfterCold: JSONObject? = null
    var coldTileBytes = 0L
    val observer = Observer()
    val executor = TimedExecutor(observer)
    val worker = PdfSessionWorker(opener = PdfSessionOpener { path, generation ->
      val real = PdfSession.open(path, generation)
      object : PdfSessionResource by real {
        override fun renderTiles(requests: List<PdfTileRequest>, beforeEach: () -> Unit): List<PdfTile> {
          val record = Render(requests.single().key, requests.single().priority, checkNotNull(executor.current.get()))
          observer.renders.add(record)
          record.start = now()
          try { return real.renderTiles(requests, beforeEach) }
          finally { record.end = now() }
        }
      }
    }, executorOverride = executor)
    val generation = worker.reserveOpenAttemptId(0L)
    val opened = CountDownLatch(1)
    var info: PdfSessionInfo? = null
    var failure: Throwable? = null
    worker.prepareOpen(generation, source.absolutePath, null) { candidate ->
      candidate.onSuccess { prepared ->
        info = prepared
        worker.commitPreparedOpen(generation) { committed ->
          failure = committed.exceptionOrNull(); opened.countDown()
        }
      }.onFailure { failure = it; opened.countDown() }
    }
    assertTrue("PDF open timed out", opened.await(30, TimeUnit.SECONDS))
    failure?.let { throw it }
    val page = checkNotNull(info).pages.first()
    lateinit var controller: InkDocumentController
    var installed: InkDocumentController? = null
    var phase: Phase? = null
    var hardware = false
    try {
      instrumentation.runOnMainSync {
        controller = InkDocumentController(context, worker,
          requestInvalidate = { observer.observe(); activity.drawing.invalidate() },
          requestAnimation = { activity.drawing.postInvalidateOnAnimation() },
          currentDocumentGeneration = { generation }, currentPageIndex = { 0 }, currentPageSwitchId = { 1L })
        installed = controller
        observer.controller = controller
        controller.onSizeChanged(activity.drawing.width, activity.drawing.height)
        val fit = PageViewport(page, ViewportSize(activity.drawing.width.toDouble(),
          activity.drawing.height.toDouble(), context.resources.displayMetrics.density.toDouble())).fitZoom()
        val zoom = fit * 3.0
        activity.drawFrame = { canvas ->
          hardware = canvas.isHardwareAccelerated
          controller.draw(canvas)
          observer.observe()
          phase?.let { current ->
            val state = controller.tilePresentationStateForTest()
            val hasPixels = observer.snapshot().any { it.accepted != 0L && it.key in state.displayedVisibleKeys }
            if (hasPixels && current.firstDraw == 0L) current.firstDraw = now()
            current.draws++
            if (!controller.visibleTilesDrawn) current.incompleteDraws++
            if (controller.visibleTilesDrawn && current.motionDone && current.covered == 0L) {
              current.covered = now(); current.done.countDown()
            }
          }
        }
        phase = Phase("cold", observer.renders.size)
        controller.setPage(page, zoom, PagePoint(page.width / 2, page.height / 2), fitToPage = false)
      }
      finishPhase(checkNotNull(phase), observer, image, iteration, controller) { hardware }
      waitUntilIdle(controller)
      memoryAfterCold = memorySnapshot()
      instrumentation.runOnMainSync { coldTileBytes = controller.tileCacheBytes }
      instrumentation.runOnMainSync {
        phase = Phase("warm", observer.renders.size)
        activity.drawing.invalidate()
      }
      finishPhase(checkNotNull(phase), observer, image, iteration, controller) { hardware }

      val motion = CountDownLatch(1)
      instrumentation.runOnMainSync {
        phase = Phase("pan-reverse", observer.renders.size).apply { motionDone = false }
        val current = checkNotNull(phase)
        val zoom = checkNotNull(controller.viewportSnapshot()).zoom
        val scheduled = SystemClock.uptimeMillis()
        val handler = Handler(Looper.getMainLooper())
        for (step in 0..120) {
          val target = scheduled + step * 16L
          handler.postAtTime({
            current.maxStepLatenessMs = maxOf(current.maxStepLatenessMs, SystemClock.uptimeMillis() - target)
            val progress = if (step <= 60) step / 60.0 else (120 - step) / 60.0
            observer.inViewportUpdate = true
            try {
              controller.applyViewport(ViewportRequest.FocusAndZoom(
                PagePoint(page.width * (0.2 + 0.6 * progress), page.height * (0.25 + 0.5 * progress)), zoom))
            } finally { observer.inViewportUpdate = false }
            if (step == 120) {
              current.motionDone = true; current.motionEnd = now(); activity.drawing.invalidate(); motion.countDown()
            }
          }, target)
        }
      }
      assertTrue("Scripted pan timed out", motion.await(30, TimeUnit.SECONDS))
      finishPhase(checkNotNull(phase), observer, image, iteration, controller) { hardware }
      waitUntilIdle(controller)
    } finally {
      instrumentation.runOnMainSync { activity.drawFrame = null; installed?.dispose() }
      worker.close()
      assertTrue("PDF worker shutdown timed out", executor.awaitTermination(30, TimeUnit.SECONDS))
      memoryResults.put(JSONObject().put("workload", if (image) "image" else "vector")
        .put("iteration", iteration).put("beforeOpen", memoryBefore).put("afterColdDrain", memoryAfterCold)
        .put("afterClose", memorySnapshot()).put("coldTileBytes", coldTileBytes))
    }
  }

  private fun finishPhase(phase: Phase, observer: Observer, image: Boolean, iteration: Int,
                          controller: InkDocumentController, hardware: () -> Boolean) {
    assertTrue("${phase.name} coverage timed out", phase.done.await(30, TimeUnit.SECONDS))
    instrumentation.runOnMainSync {
      observer.observe()
      assertTrue("Measurement requires hardware canvas drawing", hardware())
      val records = observer.snapshot().drop(phase.firstRecord).filter { it.end != 0L && it.end <= phase.covered }
      val sample = JSONObject().put("workload", if (image) "image" else "vector").put("iteration", iteration)
        .put("phase", phase.name).put("hardwareCanvas", hardware()).put("startNs", phase.start)
        .put("firstDrawNs", phase.firstDraw).put("coveredNs", phase.covered).put("motionEndNs", phase.motionEnd)
        .put("draws", phase.draws).put("incompleteDraws", phase.incompleteDraws)
        .put("maxStepLatenessMs", phase.maxStepLatenessMs).put("tileCacheBytes", controller.tileCacheBytes)
        .put("renders", JSONArray(records.map { record ->
          JSONObject().put("key", record.key.toString()).put("priority", record.priority).put("submitNs", record.job.submit)
            .put("submissionCause", record.job.cause)
            .put("workerStartNs", record.job.start).put("renderStartNs", record.start)
            .put("renderEndNs", record.end).put("acceptedNs", record.accepted).put("discarded", record.discarded)
        }))
      results.put(sample)
      Log.i("InkSignTileBenchmark", "${sample.getString("workload")} ${phase.name} #$iteration coverageMs=${(phase.covered - phase.start) / 1e6} tiles=${records.size}")
    }
  }

  private fun waitUntilIdle(controller: InkDocumentController) {
    val deadline = now() + TimeUnit.SECONDS.toNanos(30)
    while (now() < deadline) {
      var idle = false
      instrumentation.runOnMainSync { idle = controller.tilePresentationStateForTest().pendingKeys.isEmpty() }
      if (idle) return
      Thread.sleep(20)
    }
    error("Tile prefetch did not drain")
  }

  private fun fixture(image: Boolean): File {
    val file = File.createTempFile("tile-benchmark-", ".pdf", context.cacheDir)
    val document = PdfDocument()
    try {
      val page = document.startPage(PdfDocument.PageInfo.Builder(612, 792, 1).create())
      val paint = Paint().apply { textSize = 8f }
      if (image) {
        val bitmap = Bitmap.createBitmap(3072, 4096, Bitmap.Config.ARGB_8888)
        try {
          val canvas = Canvas(bitmap)
          for (y in 0 until bitmap.height step 8) for (x in 0 until bitmap.width step 8) {
            paint.color = Color.rgb((x / 8 + y / 8) % 256, (x / 8 * 3) % 256, (y / 8 * 5) % 256)
            canvas.drawRect(x.toFloat(), y.toFloat(), x + 8f, y + 8f, paint)
          }
          page.canvas.drawBitmap(bitmap, null, RectF(0f, 0f, 612f, 792f), paint)
        } finally { bitmap.recycle() }
      } else {
        for (y in 0..100) for (x in 0..10) {
          paint.color = Color.rgb(x * 20, y * 2, 120)
          page.canvas.drawText("Field $x/$y", x * 56f, 8f + y * 7.7f, paint)
          page.canvas.drawLine(x * 56f, 10f + y * 7.7f, x * 56f + 45f, 10f + y * 7.7f, paint)
        }
      }
      document.finishPage(page)
      file.outputStream().use(document::writeTo)
    } finally { document.close() }
    return file
  }

  private fun memorySnapshot(): JSONObject {
    val info = Debug.MemoryInfo()
    Debug.getMemoryInfo(info)
    val runtime = Runtime.getRuntime()
    return JSONObject().put("nativeHeapBytes", Debug.getNativeHeapAllocatedSize())
      .put("javaHeapBytes", runtime.totalMemory() - runtime.freeMemory()).put("pssKb", info.totalPss)
  }

  private class Phase(val name: String, val firstRecord: Int) {
    val start = now()
    var firstDraw = 0L
    var covered = 0L
    var motionEnd = start
    var motionDone = true
    var draws = 0
    var incompleteDraws = 0
    var maxStepLatenessMs = 0L
    val done = CountDownLatch(1)
  }

  private class Job(val cause: String, val submit: Long = now()) { @Volatile var start = 0L }
  private class Render(val key: PdfTileKey, val priority: Int, val job: Job) {
    @Volatile var start = 0L
    @Volatile var end = 0L
    var accepted = 0L
    var discarded = false
  }

  private class Observer {
    val renders = Collections.synchronizedList(ArrayList<Render>())
    var controller: InkDocumentController? = null
    var inViewportUpdate = false
    fun snapshot(): List<Render> = synchronized(renders) { renders.toList() }
    fun observe() {
      val state = controller?.tilePresentationStateForTest() ?: return
      val stamp = now()
      for (record in snapshot()) if (record.end != 0L && record.accepted == 0L && !record.discarded && record.key !in state.pendingKeys) {
        if (record.key in state.activeVisibleKeys || record.key in state.activePrefetchKeys) record.accepted = stamp
        else record.discarded = true
      }
    }
  }

  private class TimedExecutor(val observer: Observer) : AbstractExecutorService() {
    private val delegate = Executors.newSingleThreadExecutor()
    val current = ThreadLocal<Job>()
    override fun execute(command: Runnable) {
      if (Looper.myLooper() == Looper.getMainLooper()) observer.observe()
      val job = Job(if (observer.inViewportUpdate) "viewport" else "continuation")
      delegate.execute { current.set(job); job.start = now(); try { command.run() } finally { current.remove() } }
    }
    override fun shutdown() = delegate.shutdown()
    override fun shutdownNow(): MutableList<Runnable> = delegate.shutdownNow()
    override fun isShutdown() = delegate.isShutdown
    override fun isTerminated() = delegate.isTerminated
    override fun awaitTermination(timeout: Long, unit: TimeUnit) = delegate.awaitTermination(timeout, unit)
  }

  companion object { private fun now(): Long = SystemClock.elapsedRealtimeNanos() }
}
