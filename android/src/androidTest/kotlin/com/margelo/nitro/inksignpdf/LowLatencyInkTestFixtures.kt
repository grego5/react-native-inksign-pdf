package com.margelo.nitro.inksignpdf

import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.graphics.lowlatency.CanvasFrontBufferedRenderer
import androidx.test.platform.app.InstrumentationRegistry
import java.util.ArrayDeque
import org.junit.Before

internal abstract class LowLatencyInkPresenterTestBase {
  protected val instrumentation: Instrumentation = InstrumentationRegistry.getInstrumentation()

  @Before
  fun setUp() {
    NativeTestRuntime.initialize()
  }

  protected fun presenter(
    created: MutableList<FakeRenderer>,
    rendererValid: Boolean = true,
    surfaceValid: Boolean = true,
    beforeDiagnosticsPublish: () -> Unit = {},
  ): LowLatencyInkPresenter {
    return LowLatencyInkPresenter(
      instrumentation.targetContext,
      LowLatencyInkRendererFactory { _, callback ->
        FakeRenderer(rendererValid, callback).also { created += it }
      },
      surfaceValidity = { surfaceValid },
      beforeDiagnosticsPublish = beforeDiagnosticsPublish,
    )
  }

  protected fun drawRequest(
    sequence: Long,
    left: Int = 0,
    top: Int = 0,
    right: Int = 1,
    bottom: Int = 1,
    generation: Long = 0L,
  ) = LowLatencyInkDrawRequest(
    generation = generation,
    sequence = sequence,
    dirtyRegion = InkDirtyRegion(left, top, right, bottom),
    pageToView = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
    bufferWidth = 300,
    bufferHeight = 300,
    paths = emptyList(),
    realPathCount = 0,
    predictionPathCount = 0,
  )

  protected fun rectDrawRequest(
    sequence: Long,
    left: Int,
    top: Int,
    right: Int,
    bottom: Int,
  ) = LowLatencyInkDrawRequest(
    generation = 1L,
    sequence = sequence,
    dirtyRegion = InkDirtyRegion(left, top, right, bottom),
    pageToView = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
    bufferWidth = 300,
    bufferHeight = 300,
    paths = listOf(
      LowLatencyInkDrawPath(
        key = "ordered-$sequence",
        data = InkPathData(
          commands = listOf(
            InkPathCommand(InkPathCommand.MOVE, left.toFloat(), top.toFloat()),
            InkPathCommand(InkPathCommand.LINE, right.toFloat(), top.toFloat()),
            InkPathCommand(InkPathCommand.LINE, right.toFloat(), bottom.toFloat()),
            InkPathCommand(InkPathCommand.LINE, left.toFloat(), bottom.toFloat()),
            InkPathCommand(InkPathCommand.CLOSE),
          ),
          bounds = InkBounds(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat()),
        ),
        role = LowLatencyInkPathRole.REAL,
        color = Color.CYAN,
      ),
    ),
    realPathCount = 1,
    predictionPathCount = 0,
  )

  protected fun multiRectDrawRequest(
    sequence: Long,
    dirtyRegion: InkDirtyRegion,
    paths: List<LowLatencyInkDrawPath>,
  ) = LowLatencyInkDrawRequest(
    generation = 1L,
    sequence = sequence,
    dirtyRegion = dirtyRegion,
    pageToView = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
    bufferWidth = 300,
    bufferHeight = 300,
    paths = paths,
    realPathCount = paths.size,
    predictionPathCount = 0,
  )
}

internal class FakeRenderer(
  var valid: Boolean,
  private val callback: CanvasFrontBufferedRenderer.Callback<LowLatencyInkRenderToken>? = null,
) : LowLatencyInkRenderer {
  val requests = ArrayDeque<LowLatencyInkRenderToken>()
  val operations = ArrayList<String>()
  val commitCallbackTokens = ArrayList<List<LowLatencyInkRenderToken>>()
  var throwOnRender = false
  var clearCount = 0
  var cancelCount = 0
  var commitCount = 0
  var deferCommitCallback = false
  var commitOnWorkerThread = false
  var releaseCount = 0
    private set
  private var releaseCallback: (() -> Unit)? = null
  private var commitCallbackThread: Thread? = null

  override fun isValid() = valid

  override fun renderFrontBufferedLayer(token: LowLatencyInkRenderToken) {
    if (throwOnRender) throw IllegalStateException("synthetic renderer submission failure")
    requests.add(token)
    operations += "front"
  }

  override fun commit() {
    commitCount += 1
    operations += "commit"
    val retained = requests.toList()
    commitCallbackTokens += retained
    if (deferCommitCallback) return
    if (commitOnWorkerThread) {
      commitCallbackThread = Thread { completeCommitCallback(retained) }.also { it.start() }
    } else {
      completeCommitCallback(retained)
    }
  }

  fun completeDeferredCommit() {
    completeCommitCallback(commitCallbackTokens.last())
  }

  fun awaitCommitCallback() {
    commitCallbackThread?.join(5_000)
  }

  private fun completeCommitCallback(retained: List<LowLatencyInkRenderToken>) {
    callback?.onDrawMultiBufferedLayer(
      Canvas(Bitmap.createBitmap(300, 300, Bitmap.Config.ARGB_8888)),
      300,
      300,
      retained,
    )
    (callback as? LowLatencyInkDrawCallback)?.completeMultiBufferedLayerForTest()
  }

  override fun clear() {
    clearCount += 1
    (callback as? LowLatencyInkDrawCallback)?.completeMultiBufferedLayerForTest()
  }

  override fun cancel() {
    cancelCount += 1
  }

  override fun release(cancelPending: Boolean, onReleaseComplete: () -> Unit) {
    releaseCount += 1
    releaseCallback = onReleaseComplete
  }

  fun completeRelease() {
    releaseCallback?.invoke()
    releaseCallback = null
  }
}

internal class NoOpOverlayListener : LowLatencyInkView.Listener {
  override fun onOverlayAttached(view: LowLatencyInkView) = Unit
  override fun onOverlayDetached(view: LowLatencyInkView) = Unit
  override fun onOverlaySurfaceCreated(view: LowLatencyInkView) = Unit
  override fun onOverlaySurfaceDestroyed(view: LowLatencyInkView) = Unit
  override fun onOverlaySizeChanged(view: LowLatencyInkView, width: Int, height: Int) = Unit
}
