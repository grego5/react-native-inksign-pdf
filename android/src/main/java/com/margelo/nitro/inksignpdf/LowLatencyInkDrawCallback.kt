package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RenderNode
import android.os.Handler
import android.os.Looper
import androidx.graphics.lowlatency.CanvasFrontBufferedRenderer
import androidx.graphics.surface.SurfaceControlCompat
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max

private sealed interface LowLatencyInkMultiBufferCompletion {
  data class Final(val token: LowLatencyInkRenderToken?, val drawn: Boolean) :
    LowLatencyInkMultiBufferCompletion
  data class Clear(val generation: Long) : LowLatencyInkMultiBufferCompletion
}

private class LowLatencyInkMultiBufferCompletionQueue {
  private val lock = Any()
  private val entries = ArrayDeque<LowLatencyInkMultiBufferCompletion>()

  fun append(entry: LowLatencyInkMultiBufferCompletion) = synchronized(lock) {
    entries.addLast(entry)
  }

  fun removeFirst(): LowLatencyInkMultiBufferCompletion? = synchronized(lock) {
    if (entries.isEmpty()) null else entries.removeFirst()
  }
}

/**
 * Worker-side modified-region callback. Every RenderNode and Path created here is worker-owned;
 * only immutable request data crosses the AndroidX callback boundary.
 */
internal class LowLatencyInkDrawCallback(
  private val currentGeneration: AtomicLong,
  private val lastConsumedSequence: AtomicLong,
  private val payloads: LowLatencyInkPayloadMailbox,
  private val acknowledgeOnUi: (LowLatencyInkPresentationAcknowledgement) -> Unit = {},
  private val mainHandler: Handler = Handler(Looper.getMainLooper()),
  private val finalSnapshotFor: (LowLatencyInkRenderToken) -> LowLatencyInkFinalSnapshot? = { null },
  private val beforeDiagnosticsPublish: () -> Unit = {},
  private val onMultiBufferedLayerPrepared: (Long, Long, Boolean) -> Unit = { _, _, _ -> },
) : CanvasFrontBufferedRenderer.Callback<LowLatencyInkRenderToken> {
  private val diagnosticsSnapshot = AtomicReference(LowLatencyInkDrawDiagnostics())
  private val sourcePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    isDither = true
  }
  private val replacementPaint = Paint().apply { blendMode = android.graphics.BlendMode.SRC }
  private val pageMatrix = Matrix()
  private var offscreenFrameBuffer: RenderNode? = null
  private var offscreenWidth = 0
  private var offscreenHeight = 0
  private var stableBitmap: Bitmap? = null
  private var workerStateGeneration = Long.MIN_VALUE
  private var stableGeneration = Long.MIN_VALUE
  private var stableBakedBoundary = 0L
  private val pathCache = HashMap<String, CachedPath>()
  private var resetCount = 0L
  private var staleRequestCount = 0L
  private var copiedPathCount = 0L
  private var pathRecordingCount = 0L
  private var callbackCount = 0L
  private var drawingCallbackCount = 0L
  private var staleCallbackCount = 0L
  private var cyanRealPathCount = 0L
  private var magentaPredictionPathCount = 0L
  private var renderedRegionCount = 0L
  private var submitToCallbackStartDurationNanos = 0L
  private var offscreenRecordingDurationNanos = 0L
  private var replacementDurationNanos = 0L
  private var finalSnapshotDrawCount = 0L
  @Volatile private var committedFinalToken: LowLatencyInkRenderToken? = null
  private val completions = LowLatencyInkCompletionQueue()
  private val multiBufferCompletions = LowLatencyInkMultiBufferCompletionQueue()

  private data class CachedPath(
    val data: InkPathData,
    val color: Int,
    val node: RenderNode,
  )

  private fun setPageMatrix(transform: PageTransform) {
    pageMatrix.setValues(floatArrayOf(
      transform.a.toFloat(), transform.b.toFloat(), transform.tx.toFloat(),
      transform.c.toFloat(), transform.d.toFloat(), transform.ty.toFloat(),
      0f, 0f, 1f,
    ))
  }

  fun installFinalSnapshot(token: LowLatencyInkRenderToken) {
    committedFinalToken = token
  }

  fun clearFinalSnapshot() {
    committedFinalToken = null
  }

  fun enqueueFinalClear(generation: Long) {
    multiBufferCompletions.append(LowLatencyInkMultiBufferCompletion.Clear(generation))
  }

  override fun onDrawFrontBufferedLayer(
    canvas: Canvas,
    bufferWidth: Int,
    bufferHeight: Int,
    param: LowLatencyInkRenderToken,
  ) {
    callbackCount += 1L
    InkPerfetto.counter("InkSign front-buffer callback received", callbackCount)
    InkPerfetto.instantMarker("InkSign/front-buffer callback received")
    val callbackStart = InkPerfetto.nowNanos()
    var requestParam: LowLatencyInkDrawRequest? = null
    var completion: LowLatencyInkPresentationAcknowledgement? = null
    try {
      requestParam = payloads.resolve(param)
      if (requestParam == null) {
        staleRequestCount += 1L
        staleCallbackCount += 1L
        InkPerfetto.counter("InkSign front-buffer callback stale", staleCallbackCount)
        InkPerfetto.instantMarker("InkSign/front-buffer callback missing payload")
        return
      }
      val request = requestParam
      if (request.submitRequestedAtNanos > 0L) {
        submitToCallbackStartDurationNanos +=
          (callbackStart - request.submitRequestedAtNanos).coerceAtLeast(0L)
      }
      if (request.generation != currentGeneration.get() ||
        request.sequence <= lastConsumedSequence.get()
      ) {
        staleRequestCount += 1L
        staleCallbackCount += 1L
        InkPerfetto.counter("InkSign front-buffer callback stale", staleCallbackCount)
        InkPerfetto.instantMarker("InkSign/front-buffer callback stale")
        return
      }
      lastConsumedSequence.set(request.sequence)
      if (request.dirtyRegion.isEmpty && !request.reset) return
      workerStateGeneration = request.generation
      drawingCallbackCount += 1L
      InkPerfetto.instantMarker("InkSign/front-buffer callback drawing")
      InkPerfetto.counter("InkSign front-buffer callback drawing", drawingCallbackCount)
      cyanRealPathCount += request.paths.count {
        it.role == LowLatencyInkPathRole.REAL && it.color == Color.CYAN
      }
      magentaPredictionPathCount += request.paths.count {
        it.role == LowLatencyInkPathRole.PREDICTION && it.color == Color.MAGENTA
      }
      require(request.bufferWidth == bufferWidth && request.bufferHeight == bufferHeight)
      ensureStableBitmap(bufferWidth, bufferHeight, request.generation)
      bakeStablePaths(request)
      ensureOffscreenFrameBuffer(bufferWidth, bufferHeight)

      val offscreen = checkNotNull(offscreenFrameBuffer)
      val recordingStart = InkPerfetto.nowNanos()
      val offscreenCanvas = offscreen.beginRecording(bufferWidth, bufferHeight)
      try {
        offscreenCanvas.save()
        offscreenCanvas.clipRect(
          request.dirtyRegion.left.toFloat(),
          request.dirtyRegion.top.toFloat(),
          request.dirtyRegion.right.toFloat(),
          request.dirtyRegion.bottom.toFloat(),
        )
        offscreenCanvas.drawColor(Color.TRANSPARENT, android.graphics.BlendMode.CLEAR)
        offscreenCanvas.drawBitmap(checkNotNull(stableBitmap), 0f, 0f, null)
        setPageMatrix(request.pageToView)
        offscreenCanvas.concat(pageMatrix)
        for (drawPath in request.paths) {
          if (drawPath.stable) continue
          val cached = cachedPath(drawPath)
          offscreenCanvas.drawRenderNode(cached.node)
        }
        offscreenCanvas.restore()
      } finally {
        offscreen.endRecording()
        offscreenRecordingDurationNanos +=
          (InkPerfetto.nowNanos() - recordingStart).coerceAtLeast(0L)
      }

      val replacementStart = InkPerfetto.nowNanos()
      canvas.save()
      canvas.clipRect(
        request.dirtyRegion.left.toFloat(),
        request.dirtyRegion.top.toFloat(),
        request.dirtyRegion.right.toFloat(),
        request.dirtyRegion.bottom.toFloat(),
      )
      // The SRC compositing layer replaces transparent pixels too, so obsolete tail and
      // prediction pixels are removed atomically with the redraw in this clip.
      if (canvas.isHardwareAccelerated) {
        canvas.drawRenderNode(offscreen)
      } else {
        // Instrumented bitmap tests use a software Canvas. AndroidX supplies a hardware Canvas in
        // production, but replay the same retained sources here so the replacement contract remains
        // testable without asking software rendering to execute a RenderNode display list.
        canvas.drawColor(Color.TRANSPARENT, android.graphics.BlendMode.CLEAR)
        canvas.drawBitmap(checkNotNull(stableBitmap), 0f, 0f, null)
        canvas.concat(pageMatrix)
        for (drawPath in request.paths) {
          if (drawPath.stable) continue
          sourcePaint.color = drawPath.color
          canvas.drawPath(drawPath.data.toPath(), sourcePaint)
        }
      }
      canvas.restore()
      replacementDurationNanos +=
        (InkPerfetto.nowNanos() - replacementStart).coerceAtLeast(0L)
      InkPerfetto.counter("InkSign front-buffer callback real paths", request.realPathCount)
      InkPerfetto.counter(
        "InkSign front-buffer callback prediction paths",
        request.predictionPathCount,
      )
      InkPerfetto.counter(
        "InkSign front-buffer callback has prediction",
        if (request.predictionPathCount > 0) 1 else 0,
      )
      renderedRegionCount += 1L
      InkPerfetto.counter("InkSign front-buffer rendered regions", renderedRegionCount)
      InkPerfetto.instantMarker("InkSign/front-buffer rendered region")
      if (request.reset) resetCount += 1L
      completion = LowLatencyInkPresentationAcknowledgement(
        generation = request.generation,
        sequence = request.sequence,
        stableBoundary = request.stableBoundary,
      )
    } finally {
      requestParam?.let { payloads.complete(param) }
      completions.append(completion)
      InkPerfetto.endAsyncUpdate(requestParam?.sequence ?: param.sequence)
      publishDiagnostics()
    }
  }

  override fun onFrontBufferedLayerRenderComplete(
    frontBufferedLayerSurfaceControl: SurfaceControlCompat,
    transaction: SurfaceControlCompat.Transaction,
  ) {
    completeFrontBufferedLayer()
  }

  internal fun completeFrontBufferedLayerForTest() {
    completeFrontBufferedLayer()
  }

  private fun completeFrontBufferedLayer() {
    val acknowledgement = completions.removeFirst() ?: return
    pruneStablePathCache(acknowledgement.stableBoundary)
    mainHandler.post { acknowledgeOnUi(acknowledgement) }
  }

  private fun ensureStableBitmap(width: Int, height: Int, generation: Long) {
    val current = stableBitmap
    if (current != null && current.width == width && current.height == height &&
      stableGeneration == generation
    ) return
    current?.recycle()
    stableBitmap = Bitmap.createBitmap(max(1, width), max(1, height), Bitmap.Config.ARGB_8888)
    stableGeneration = generation
    stableBakedBoundary = 0L
    clearPathCache()
  }

  private fun bakeStablePaths(request: LowLatencyInkDrawRequest) {
    var canvas: Canvas? = null
    var newestStableBoundary = stableBakedBoundary
    for (drawPath in request.paths) {
      if (!drawPath.stable) continue
      if (drawPath.stableContourStart < 0L) {
        if (stableBakedBoundary != 0L) continue
      } else if (drawPath.stableContourStart < stableBakedBoundary) {
        continue
      }
      if (canvas == null) {
        val createdCanvas = Canvas(checkNotNull(stableBitmap))
        setPageMatrix(request.pageToView)
        createdCanvas.concat(pageMatrix)
        canvas = createdCanvas
      }
      val drawingCanvas = checkNotNull(canvas)
      sourcePaint.color = drawPath.color
      drawingCanvas.drawPath(drawPath.data.toPath(), sourcePaint)
      newestStableBoundary = maxOf(newestStableBoundary, drawPath.stableContourEnd)
    }
    if (canvas != null) stableBakedBoundary = newestStableBoundary
  }

  private fun pruneStablePathCache(stableBoundary: Long) {
    val iterator = pathCache.entries.iterator()
    while (iterator.hasNext()) {
      val entry = iterator.next()
      val key = entry.key
      val remove = when {
        key.startsWith("stable-real/") -> true
        key.startsWith("real/") -> key.substringAfter("real/").toLongOrNull()
          ?.let { it < stableBoundary } == true
        else -> false
      }
      if (remove) {
        entry.value.node.discardDisplayList()
        iterator.remove()
      }
    }
  }

  override fun onDrawMultiBufferedLayer(
    canvas: Canvas,
    bufferWidth: Int,
    bufferHeight: Int,
    params: Collection<LowLatencyInkRenderToken>,
  ) {
    val token = committedFinalToken
    var drawn = false
    try {
      val snapshot = token?.let(finalSnapshotFor)
      if (snapshot == null) {
        staleCallbackCount += 1L
      } else {
        require(snapshot.generation == token.generation && snapshot.sequence == token.sequence)
        require(snapshot.bufferWidth == bufferWidth && snapshot.bufferHeight == bufferHeight)
        setPageMatrix(snapshot.pageToView)
        sourcePaint.color = snapshot.color
        canvas.concat(pageMatrix)
        snapshot.paths.forEach { path -> canvas.drawPath(path.toPath(), sourcePaint) }
        finalSnapshotDrawCount += 1L
        drawn = true
        InkPerfetto.counter("InkSign final multi-buffer snapshots drawn", finalSnapshotDrawCount)
      }
    } finally {
      multiBufferCompletions.append(
        LowLatencyInkMultiBufferCompletion.Final(token, drawn),
      )
      publishDiagnostics()
    }
  }

  override fun onMultiBufferedLayerRenderComplete(
    frontBufferedLayerSurfaceControl: SurfaceControlCompat,
    multiBufferedLayerSurfaceControl: SurfaceControlCompat,
    transaction: SurfaceControlCompat.Transaction,
  ) {
    completeMultiBufferedLayer()
  }

  internal fun completeMultiBufferedLayerForTest() {
    completeMultiBufferedLayer()
  }

  private fun completeMultiBufferedLayer() {
    when (val completion = multiBufferCompletions.removeFirst()) {
      is LowLatencyInkMultiBufferCompletion.Final -> {
        completion.token?.let { token ->
          onMultiBufferedLayerPrepared(token.generation, token.sequence, completion.drawn)
        } ?: run { staleCallbackCount += 1L }
      }
      is LowLatencyInkMultiBufferCompletion.Clear -> {
        if (completion.generation == workerStateGeneration) {
          clearWorkerState()
        } else {
          staleCallbackCount += 1L
        }
      }
      null -> staleCallbackCount += 1L
    }
    publishDiagnostics()
  }

  fun diagnostics(): LowLatencyInkDrawDiagnostics = diagnosticsSnapshot.get()

  private fun publishDiagnostics() {
    beforeDiagnosticsPublish()
    diagnosticsSnapshot.set(LowLatencyInkDrawDiagnostics(
      resetCount = resetCount,
      staleRequestCount = staleRequestCount,
      copiedPathCount = copiedPathCount,
      pathRecordingCount = pathRecordingCount,
      callbackCount = callbackCount,
      drawingCallbackCount = drawingCallbackCount,
      staleCallbackCount = staleCallbackCount,
      cyanRealPathCount = cyanRealPathCount,
      magentaPredictionPathCount = magentaPredictionPathCount,
      renderedRegionCount = renderedRegionCount,
      submitToCallbackStartDurationNanos = submitToCallbackStartDurationNanos,
      offscreenRecordingDurationNanos = offscreenRecordingDurationNanos,
      replacementDurationNanos = replacementDurationNanos,
      finalMultiBufferSnapshotDrawCount = finalSnapshotDrawCount,
      workerStableBitmapPresent = stableBitmap != null,
      workerPathCacheCount = pathCache.size,
      workerOffscreenPresent = offscreenFrameBuffer != null,
    ))
  }

  private fun clearWorkerState() {
    stableBitmap?.recycle()
    stableBitmap = null
    workerStateGeneration = Long.MIN_VALUE
    stableGeneration = Long.MIN_VALUE
    stableBakedBoundary = 0L
    clearPathCache()
    offscreenFrameBuffer?.discardDisplayList()
    offscreenFrameBuffer = null
    offscreenWidth = 0
    offscreenHeight = 0
    committedFinalToken = null
    publishDiagnostics()
  }

  private fun clearPathCache() {
    pathCache.values.forEach { it.node.discardDisplayList() }
    pathCache.clear()
  }

  private fun cachedPath(
    drawPath: LowLatencyInkDrawPath,
  ): CachedPath {
    val existing = pathCache[drawPath.key]
    if (existing != null &&
      existing.data == drawPath.data &&
      existing.color == drawPath.color
    ) return existing
    val node = RenderNode("InkSign/front-buffer-${drawPath.key}").apply {
      setClipToBounds(false)
    }
    sourcePaint.color = drawPath.color
    drawPath.data.recordInto(node, sourcePaint)
    existing?.node?.discardDisplayList()
    val cached = CachedPath(drawPath.data, drawPath.color, node)
    pathCache[drawPath.key] = cached
    copiedPathCount += 1L
    pathRecordingCount += 1L
    return cached
  }

  private fun ensureOffscreenFrameBuffer(width: Int, height: Int) {
    if (offscreenFrameBuffer != null && offscreenWidth == width && offscreenHeight == height) return
    offscreenFrameBuffer?.discardDisplayList()
    offscreenFrameBuffer = RenderNode("LowLatencyInkPresenter-OffScreen").apply {
      setPosition(0, 0, width, height)
      setHasOverlappingRendering(true)
      setUseCompositingLayer(true, replacementPaint)
    }
    offscreenWidth = width
    offscreenHeight = height
  }
}
