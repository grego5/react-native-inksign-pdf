package com.margelo.nitro.inksignpdf

/** UI-thread-owned contour collection for active real ink and disposable prediction. */
internal class FrontBufferStrokeComposition {
    internal data class RetainedDiagnostics(
        val committedContourCount: Int,
        val predictionContourCount: Int,
    )

    private val committedContours = ArrayList<StrokeOutline>()
    private val predictionContours = ArrayList<StrokeOutline>()
    private var latestCommittedRevision = 0L
    var activeGeneration = 0L
        private set
    private var latestAcknowledgedSequence = -1L
    private var currentMutableBounds: InkBounds? = null
    private var currentPredictionBounds: InkBounds? = null

    fun retainedDiagnostics() = RetainedDiagnostics(
        committedContours.size, predictionContours.size,
    )

    fun reset(generation: Long) {
        require(generation >= 0L)
        activeGeneration = generation
        clearState()
    }

    fun clear() = clearState()

    fun applyCommittedFrame(frame: InkStrokeFrame, generation: Long = activeGeneration) {
        require(frame.type == InkStrokeFrameCodec.COMMITTED_TYPE)
        requireActiveGeneration(generation)
        require(frame.revision >= latestCommittedRevision) {
            "Committed frame revision moved backwards"
        }
        clearPrediction()
        committedContours.clear()
        committedContours.ensureCapacity(frame.contours.size)
        frame.contours.forEach { contour ->
            committedContours += StrokeOutline.copyOf(contour)
        }
        latestCommittedRevision = frame.revision
        currentMutableBounds = boundsFor(committedContours)
    }

    fun applyPredictionFrame(frame: InkStrokeFrame, generation: Long = activeGeneration) {
        require(frame.type == InkStrokeFrameCodec.PREDICTION_TYPE)
        requireActiveGeneration(generation)
        predictionContours.clear()
        predictionContours.ensureCapacity(frame.contours.size)
        frame.contours.forEach { contour ->
            predictionContours += StrokeOutline.copyOf(contour)
        }
        currentPredictionBounds = boundsFor(predictionContours)
    }

    fun clearPrediction() {
        predictionContours.clear()
        currentPredictionBounds = null
    }

    fun frontBufferBounds() = LowLatencyInkBoundsSnapshot(
        currentMutableBounds, currentPredictionBounds, null,
    )

    fun buildFrontBufferRequest(
        generation: Long, sequence: Long, previousBounds: LowLatencyInkBoundsSnapshot?,
        pageToView: PageTransform, viewWidth: Int, viewHeight: Int, color: Int,
        dirtyRegionOverride: InkDirtyRegion? = null,
    ): LowLatencyInkDrawRequest {
        val calculated = LowLatencyInkDirtyRegionCalculator.calculate(
            previousBounds, frontBufferBounds(), pageToView, viewWidth, viewHeight,
        )
        val dirty = dirtyRegionOverride?.let { calculated?.union(it) ?: it } ?: calculated
        ?: InkDirtyRegion(0, 0, 0, 0)
        val paths = if (dirty.isEmpty) emptyList()
        else snapshotIntersectingPaths(dirty.pageBounds(pageToView), color)
        var realPathCount = 0
        var predictionPathCount = 0
        var copiedGeometryCount = 0
        paths.forEach { path ->
            when (path.role) {
                LowLatencyInkPathRole.REAL -> realPathCount += 1
                LowLatencyInkPathRole.PREDICTION -> predictionPathCount += 1
            }
            copiedGeometryCount += path.data.commands.size
        }
        return LowLatencyInkDrawRequest(
            generation, sequence, dirty, pageToView, viewWidth, viewHeight, paths,
            realPathCount,
            predictionPathCount,
            changedGeometryCount = paths.size,
            copiedGeometryCount = copiedGeometryCount,
            stableBoundary = 0L,
        )
    }

    fun acknowledgePresentation(generation: Long, sequence: Long, stableBoundary: Long): Boolean {
        require(generation >= 0L && sequence >= 0L && stableBoundary >= 0L)
        if (generation != activeGeneration || sequence <= latestAcknowledgedSequence) return false
        require(stableBoundary == 0L)
        latestAcknowledgedSequence = sequence
        return true
    }

    private fun snapshotIntersectingPaths(
        pageRegion: InkBounds, color: Int,
    ): List<LowLatencyInkDrawPath> {
        val result = ArrayList<LowLatencyInkDrawPath>()
        if (predictionContours.isNotEmpty()) {
            // Prediction is a complete replacement snapshot for the active stroke. The real
            // contours remain retained above for restoration when prediction is cleared, but must
            // not be submitted in the same request or translucent ink would be applied twice.
            predictionContours.forEachIndexed { index, contour ->
                val data = contour.contourPathData.single()
                if (data.bounds.intersects(pageRegion)) {
                    addPath(
                        result, "prediction-$index", data, color,
                        LowLatencyInkPathRole.PREDICTION
                    )
                }
            }
        } else {
            appendRealSnapshot(result, pageRegion, color)
        }
        return result
    }

    private fun appendRealSnapshot(
        destination: MutableList<LowLatencyInkDrawPath>, pageRegion: InkBounds,
        color: Int,
    ) {
        committedContours.forEachIndexed { index, contour ->
            val data = contour.contourPathData.single()
            if (data.bounds.intersects(pageRegion)) {
                addPath(destination, "real-$index", data, color, LowLatencyInkPathRole.REAL)
            }
        }
    }

    private fun addPath(
        destination: MutableList<LowLatencyInkDrawPath>, key: String,
        data: InkPathData, color: Int, role: LowLatencyInkPathRole,
        stable: Boolean = false, stableStart: Long = -1L, stableEnd: Long = -1L,
    ) {
        destination += LowLatencyInkDrawPath(
            key, data, role, color, stable, stableStart, stableEnd,
        )
    }

    private fun clearState() {
        committedContours.clear(); predictionContours.clear()
        latestCommittedRevision = 0L; latestAcknowledgedSequence = -1L
        currentMutableBounds = null; currentPredictionBounds = null
    }

    private fun requireActiveGeneration(generation: Long) = require(generation == activeGeneration)

    private fun boundsFor(contours: List<StrokeOutline>): InkBounds? {
        var result: InkBounds? = null
        contours.forEach { contour ->
            val data = contour.contourPathData.single()
            result = result?.union(data.bounds) ?: data.bounds
        }
        return result
    }
}
