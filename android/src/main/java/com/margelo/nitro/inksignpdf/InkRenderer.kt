package com.margelo.nitro.inksignpdf

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.RenderNode
import android.os.SystemClock
import kotlin.math.ceil
import kotlin.math.floor

/**
 * A bounded page-space source batch and its hardware display-list cache.
 *
 * These batches contain completed outlines only. Active real ink and prediction
 * are owned by FrontBufferStrokeComposition and rendered by AndroidX.
 */
internal class InkDisplayBatch(
    private val name: String,
) {
    private val sourcePaths = ArrayList<Path>()
    private val sourceBounds = RectF()
    private val node = RenderNode(name).apply {
        setClipToBounds(false)
    }
    private var boundsValid = false
    private var dirty = true
    private var recordedColor: Int? = null

    var sealed: Boolean = false
        private set
    var sourceSegmentCount: Long = 0L
        private set
    var sourceVerbCount: Long = 0L
        private set
    var recordingCount: Long = 0L
        private set
    var recordingDurationNanos: Long = 0L
        private set
    var renderNodeMemoryBytes: Long = 0L
        private set

    val pathCount: Int
        get() = sourcePaths.size

    val isEmpty: Boolean
        get() = sourcePaths.isEmpty()

    internal fun boundsForTest(): IntArray {
        recomputeBounds()
        return intArrayOf(
            sourceBounds.left.toInt(),
            sourceBounds.top.toInt(),
            sourceBounds.right.toInt(),
            sourceBounds.bottom.toInt(),
        )
    }

    internal fun hasDisplayListForTest(): Boolean = node.hasDisplayList()

    fun appendPath(path: Path, segmentCount: Int, verbCount: Int) {
        check(!sealed) { "Cannot mutate sealed ink display batch" }
        sourcePaths += path
        sourceSegmentCount += segmentCount.toLong()
        sourceVerbCount += verbCount.toLong()
        boundsValid = false
        dirty = true
    }

    fun removeLastPath(segmentCount: Int, verbCount: Int): Boolean {
        check(!sealed) { "Cannot mutate sealed ink display batch" }
        if (sourcePaths.isEmpty()) return false
        sourcePaths.removeAt(sourcePaths.lastIndex)
        sourceSegmentCount -= segmentCount.toLong()
        sourceVerbCount -= verbCount.toLong()
        boundsValid = false
        dirty = true
        return true
    }

    fun seal() {
        check(!isEmpty) { "Cannot seal an empty ink display batch" }
        sealed = true
    }

    fun reopen() {
        sealed = false
        dirty = true
    }

    fun markDirty() {
        dirty = true
    }

    fun discardDisplayList() {
        node.discardDisplayList()
        renderNodeMemoryBytes = 0L
        dirty = true
    }

    fun release() {
        node.discardDisplayList()
        sourcePaths.clear()
        sourceSegmentCount = 0L
        sourceVerbCount = 0L
        renderNodeMemoryBytes = 0L
        boundsValid = false
        dirty = true
        recordedColor = null
    }

    fun draw(canvas: Canvas, paint: Paint, hardware: Boolean) {
        if (isEmpty) return
        if (!hardware) {
            sourcePaths.forEach { path -> canvas.drawPath(path, paint) }
            return
        }

        if (dirty || recordedColor != paint.color || !node.hasDisplayList()) {
            record(paint)
        }
        canvas.drawRenderNode(node)
    }

    private fun record(paint: Paint) {
        recomputeBounds()
        val left = sourceBounds.left.toInt()
        val top = sourceBounds.top.toInt()
        val right = sourceBounds.right.toInt()
        val bottom = sourceBounds.bottom.toInt()
        node.setPosition(left, top, right, bottom)

        val recordingWidth = maxOf(1, right - left)
        val recordingHeight = maxOf(1, bottom - top)
        val recordingStartNanos = SystemClock.elapsedRealtimeNanos()
        val recordingCanvas = node.beginRecording(recordingWidth, recordingHeight)
        try {
            recordingCanvas.translate(-left.toFloat(), -top.toFloat())
            sourcePaths.forEach { path -> recordingCanvas.drawPath(path, paint) }
        } finally {
            node.endRecording()
        }
        recordingDurationNanos +=
            (SystemClock.elapsedRealtimeNanos() - recordingStartNanos).coerceAtLeast(0L)
        dirty = false
        recordedColor = paint.color
        recordingCount += 1L
        renderNodeMemoryBytes = node.computeApproximateMemoryUsage()
    }

    private fun recomputeBounds() {
        if (boundsValid) return
        check(sourcePaths.isNotEmpty())
        var initialized = false
        sourcePaths.forEach { path ->
            if (path.isEmpty) return@forEach
            val bounds = RectF()
            path.computeBounds(bounds, true)
            if (!initialized) {
                sourceBounds.set(bounds)
                initialized = true
            } else {
                sourceBounds.union(bounds)
            }
        }
        check(initialized)
        sourceBounds.left = floor(sourceBounds.left).toFloat()
        sourceBounds.top = floor(sourceBounds.top).toFloat()
        sourceBounds.right = ceil(sourceBounds.right).toFloat()
        sourceBounds.bottom = ceil(sourceBounds.bottom).toFloat()
        boundsValid = true
    }
}

internal data class InkRendererDiagnostics(
    val sealedBatchCount: Int,
    val activeBatchCount: Int,
    val completedBatchCount: Int,
    val renderNodeApproximateMemoryBytes: Long,
    val retainedSourcePathCount: Long,
    val retainedSourceSegmentEstimate: Long,
    val retainedSourceVerbEstimate: Long,
    val retainedSourceEstimatedBytes: Long,
    val recordingCount: Long,
    val recordingDurationNanos: Long,
)

/** Owns only completed page-space ink geometry and its Canvas presentation transform. */
internal class InkRenderer {
    private companion object {
        const val COMPLETED_BATCH_SEGMENT_LIMIT = 2_048
        const val ESTIMATED_FLOAT_BYTES = 4L
        const val ESTIMATED_PATH_METADATA_BYTES = 64L
    }

    private val inkPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        isDither = true
    }
    private val pageMatrix = Matrix()
    private val pageMatrixValues = FloatArray(9).apply { this[8] = 1f }
    private val sealedCompletedBatches = ArrayList<InkDisplayBatch>()
    private var activeCompletedBatch: InkDisplayBatch? = null
    private var lastColor: Int? = null

    fun draw(
        canvas: Canvas,
        viewScale: Double,
        viewOffsetX: Double,
        viewOffsetY: Double,
        currentColor: Int,
    ) {
        pageMatrixValues[0] = viewScale.toFloat()
        pageMatrixValues[2] = viewOffsetX.toFloat()
        pageMatrixValues[4] = viewScale.toFloat()
        pageMatrixValues[5] = viewOffsetY.toFloat()
        pageMatrix.setValues(pageMatrixValues)
        canvas.save()
        canvas.concat(pageMatrix)
        inkPaint.color = currentColor
        if (lastColor != currentColor) {
            markAllBatchesDirty()
            lastColor = currentColor
        }
        val hardware = canvas.isHardwareAccelerated
        sealedCompletedBatches.forEach { it.draw(canvas, inkPaint, hardware) }
        activeCompletedBatch?.draw(canvas, inkPaint, hardware)
        reportDiagnostics()
        canvas.restore()
    }

    fun clearCompleted() {
        sealedCompletedBatches.forEach(InkDisplayBatch::release)
        activeCompletedBatch?.release()
        sealedCompletedBatches.clear()
        activeCompletedBatch = null
    }

    fun addCompletedOutline(outline: StrokeOutline) {
        outline.contourPathData.forEach(::appendCompletedPath)
    }

    private fun appendCompletedPath(data: InkPathData) {
        val segmentCount = data.commands.count { it.type == InkPathCommand.CUBIC }
        var active = activeCompletedBatch ?: startCompletedBatch()
        if (!active.isEmpty &&
            active.sourceSegmentCount + segmentCount > COMPLETED_BATCH_SEGMENT_LIMIT
        ) {
            sealActiveCompletedBatch()
            active = startCompletedBatch()
        }
        active.appendPath(data.toPath(), segmentCount, data.commands.size)
        if (active.sourceSegmentCount >= COMPLETED_BATCH_SEGMENT_LIMIT) {
            sealActiveCompletedBatch()
        }
    }

    fun removeLastCompleted(outline: StrokeOutline) {
        outline.contourPathData.asReversed().forEach { data ->
            var batch = activeCompletedBatch
            if (batch == null) {
                batch = sealedCompletedBatches.removeLastOrNull()
                    ?: error("Completed ink history and display batches diverged")
                batch.reopen()
                activeCompletedBatch = batch
            }
            val segmentCount = data.commands.count { it.type == InkPathCommand.CUBIC }
            check(batch.removeLastPath(segmentCount, data.commands.size)) {
                "Completed ink history and display batches diverged"
            }
            if (batch.isEmpty) {
                batch.release()
                activeCompletedBatch = null
            }
        }
    }

    fun setCompletedHistory(strokes: List<StrokeOutline>) {
        clearCompleted()
        strokes.forEach { stroke -> addCompletedOutline(stroke) }
    }

    fun discardDisplayLists() {
        sealedCompletedBatches.forEach(InkDisplayBatch::discardDisplayList)
        activeCompletedBatch?.discardDisplayList()
    }

    fun diagnostics(): InkRendererDiagnostics = diagnosticsSnapshot()

    private fun startCompletedBatch(): InkDisplayBatch {
        val batch = InkDisplayBatch("InkSign/completed-${sealedCompletedBatches.size}")
        activeCompletedBatch = batch
        return batch
    }

    private fun sealActiveCompletedBatch() {
        val batch = activeCompletedBatch ?: return
        if (batch.isEmpty) return
        batch.seal()
        sealedCompletedBatches += batch
        activeCompletedBatch = null
    }

    private fun markAllBatchesDirty() {
        sealedCompletedBatches.forEach(InkDisplayBatch::markDirty)
        activeCompletedBatch?.markDirty()
    }

    private fun diagnosticsSnapshot(): InkRendererDiagnostics {
        var sourcePathCount = 0L
        var sourceSegmentCount = 0L
        var sourceVerbCount = 0L
        var renderNodeBytes = 0L
        var recordings = 0L
        var recordingDurationNanos = 0L
        sealedCompletedBatches.forEach { batch ->
            sourcePathCount += batch.pathCount.toLong()
            sourceSegmentCount += batch.sourceSegmentCount
            sourceVerbCount += batch.sourceVerbCount
            renderNodeBytes += batch.renderNodeMemoryBytes
            recordings += batch.recordingCount
            recordingDurationNanos += batch.recordingDurationNanos
        }
        activeCompletedBatch?.let { batch ->
            sourcePathCount += batch.pathCount.toLong()
            sourceSegmentCount += batch.sourceSegmentCount
            sourceVerbCount += batch.sourceVerbCount
            renderNodeBytes += batch.renderNodeMemoryBytes
            recordings += batch.recordingCount
            recordingDurationNanos += batch.recordingDurationNanos
        }
        return InkRendererDiagnostics(
            sealedBatchCount = sealedCompletedBatches.size,
            activeBatchCount = if (activeCompletedBatch != null) 1 else 0,
            completedBatchCount = sealedCompletedBatches.size +
                    (if (activeCompletedBatch != null) 1 else 0),
            renderNodeApproximateMemoryBytes = renderNodeBytes,
            retainedSourcePathCount = sourcePathCount,
            retainedSourceSegmentEstimate = sourceSegmentCount,
            retainedSourceVerbEstimate = sourceVerbCount,
            retainedSourceEstimatedBytes = sourceSegmentCount * ESTIMATED_FLOAT_BYTES * 8L +
                    sourceVerbCount * ESTIMATED_PATH_METADATA_BYTES,
            recordingCount = recordings,
            recordingDurationNanos = recordingDurationNanos,
        )
    }

    private fun reportDiagnostics() {
        val snapshot = diagnosticsSnapshot()
        InkPerfetto.counter("InkSign completed sealed batch count", snapshot.sealedBatchCount)
        InkPerfetto.counter("InkSign completed active batch count", snapshot.activeBatchCount)
        InkPerfetto.counter("InkSign completed batch count", snapshot.completedBatchCount)
        InkPerfetto.counter(
            "InkSign completed RenderNode approximate memory bytes",
            snapshot.renderNodeApproximateMemoryBytes,
        )
        InkPerfetto.counter("InkSign completed retained source paths", snapshot.retainedSourcePathCount)
        InkPerfetto.counter(
            "InkSign completed retained source segment estimates",
            snapshot.retainedSourceSegmentEstimate,
        )
        InkPerfetto.counter(
            "InkSign completed retained source verb estimates",
            snapshot.retainedSourceVerbEstimate,
        )
        InkPerfetto.counter(
            "InkSign completed retained source estimated bytes",
            snapshot.retainedSourceEstimatedBytes,
        )
        InkPerfetto.counter("InkSign completed display-list recordings", snapshot.recordingCount)
        InkPerfetto.counter(
            "InkSign completed display-list recording duration ns",
            snapshot.recordingDurationNanos,
        )
    }
}
