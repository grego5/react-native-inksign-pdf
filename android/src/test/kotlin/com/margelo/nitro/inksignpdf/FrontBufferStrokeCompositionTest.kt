package com.margelo.nitro.inksignpdf

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FrontBufferStrokeCompositionTest {
    @Test
    fun emptyPredictionRemainsHarmlessToComposition() {
        val frame = InkStrokeFrameCodec.decode(emptyPredictionFrame())
        val composition = FrontBufferStrokeComposition()
        composition.reset(0L)
        composition.applyPredictionFrame(frame, 0L)
        assertEquals(0, composition.retainedDiagnostics().predictionContourCount)
    }

    @Test
    fun committedSnapshotsReplaceFewerMoreAndZeroContours() {
        val composition = FrontBufferStrokeComposition()
        composition.reset(0L)
        composition.applyCommittedFrame(
            frame(
                InkStrokeFrameCodec.COMMITTED_TYPE, 1L,
                listOf(contour(0f, 10f), contour(20f, 30f))
            ),
            0L,
        )
        assertEquals(2, composition.retainedDiagnostics().committedContourCount)

        composition.applyCommittedFrame(
            frame(InkStrokeFrameCodec.COMMITTED_TYPE, 2L, listOf(contour(40f, 50f))),
            0L,
        )
        assertEquals(1, composition.retainedDiagnostics().committedContourCount)

        val beforeEmpty = composition.frontBufferBounds()
        composition.applyCommittedFrame(
            frame(InkStrokeFrameCodec.COMMITTED_TYPE, 3L, emptyList()),
            0L,
        )
        assertEquals(0, composition.retainedDiagnostics().committedContourCount)
        val emptyRequest = composition.buildFrontBufferRequest(
            0L, 1L, beforeEmpty, identityTransform(), 300, 300, 0x8014283C.toInt(),
        )
        assertEquals(0, emptyRequest.realPathCount)
        assertTrue(emptyRequest.paths.isEmpty())

        composition.applyCommittedFrame(
            frame(
                InkStrokeFrameCodec.COMMITTED_TYPE, 4L,
                listOf(contour(60f, 70f), contour(80f, 90f), contour(100f, 110f))
            ),
            0L,
        )
        assertEquals(3, composition.retainedDiagnostics().committedContourCount)
        val moreRequest = composition.buildFrontBufferRequest(
            0L, 2L, composition.frontBufferBounds(), identityTransform(), 300, 300,
            0x8014283C.toInt(),
        )
        assertEquals(3, moreRequest.realPathCount)
    }

    @Test
    fun predictionReplacesRealPresentationAndClearRestoresTheRetainedRealSnapshot() {
        val translucentColor = 0x8014283C.toInt()
        val composition = FrontBufferStrokeComposition()
        composition.reset(0L)
        composition.applyCommittedFrame(
            frame(
                InkStrokeFrameCodec.COMMITTED_TYPE,
                1L,
                listOf(contour(0f, 10f), contour(100f, 110f)),
            ),
            0L,
        )

        val realRequest = composition.buildFrontBufferRequest(
            0L, 1L, null, identityTransform(), 300, 300, translucentColor,
        )
        assertEquals(2, realRequest.realPathCount)
        assertEquals(0, realRequest.predictionPathCount)

        val beforePredictionBounds = composition.frontBufferBounds()
        composition.applyPredictionFrame(
            frame(
                InkStrokeFrameCodec.PREDICTION_TYPE,
                2L,
                listOf(contour(0f, 10f), contour(200f, 210f)),
            ),
            0L,
        )
        val predictionRequest = composition.buildFrontBufferRequest(
            0L, 2L, beforePredictionBounds, identityTransform(), 300, 300,
            translucentColor,
        )
        assertEquals(0, predictionRequest.realPathCount)
        assertEquals(2, predictionRequest.predictionPathCount)
        assertTrue(predictionRequest.paths.all { it.color == translucentColor })
        assertTrue(predictionRequest.dirtyRegion.contains(InkDirtyRegion(0, 0, 211, 11)))

        val beforeRevisedPredictionBounds = composition.frontBufferBounds()
        composition.applyPredictionFrame(
            frame(
                InkStrokeFrameCodec.PREDICTION_TYPE,
                3L,
                listOf(contour(0f, 10f), contour(220f, 230f)),
            ),
            0L,
        )
        val revisedRequest = composition.buildFrontBufferRequest(
            0L, 3L, beforeRevisedPredictionBounds, identityTransform(), 300, 300,
            translucentColor,
        )
        assertEquals(0, revisedRequest.realPathCount)
        assertEquals(2, revisedRequest.predictionPathCount)
        assertTrue(revisedRequest.dirtyRegion.contains(InkDirtyRegion(0, 0, 231, 11)))

        val beforeClearBounds = composition.frontBufferBounds()
        composition.clearPrediction()
        val restoredRequest = composition.buildFrontBufferRequest(
            0L, 4L, beforeClearBounds, identityTransform(), 300, 300,
            translucentColor,
        )
        assertEquals(2, restoredRequest.realPathCount)
        assertEquals(0, restoredRequest.predictionPathCount)
        assertTrue(restoredRequest.paths.all { it.color == translucentColor })
        assertTrue(restoredRequest.dirtyRegion.contains(InkDirtyRegion(0, 0, 231, 11)))
    }

    @Test
    fun offRegionPredictionDoesNotRestoreRealInkUntilPredictionClears() {
        val composition = FrontBufferStrokeComposition()
        composition.reset(0L)
        composition.applyCommittedFrame(
            frame(
                InkStrokeFrameCodec.COMMITTED_TYPE,
                1L,
                listOf(contour(100f, 110f)),
            ),
            0L,
        )
        val beforePredictionBounds = composition.frontBufferBounds()
        composition.applyPredictionFrame(
            frame(
                InkStrokeFrameCodec.PREDICTION_TYPE,
                2L,
                listOf(contour(1000f, 1010f)),
            ),
            0L,
        )

        val offRegionPredictionRequest = composition.buildFrontBufferRequest(
            0L, 1L, beforePredictionBounds, identityTransform(), 300, 300, 0x8014283C.toInt(),
        )
        assertTrue(
            offRegionPredictionRequest.dirtyRegion.contains(InkDirtyRegion(100, 0, 111, 11)),
        )
        assertEquals(0, offRegionPredictionRequest.realPathCount)
        assertEquals(0, offRegionPredictionRequest.predictionPathCount)
        assertTrue(offRegionPredictionRequest.paths.isEmpty())

        val beforeClearBounds = composition.frontBufferBounds()
        composition.clearPrediction()
        val restoredRequest = composition.buildFrontBufferRequest(
            0L, 2L, beforeClearBounds, identityTransform(), 300, 300, 0x8014283C.toInt(),
        )
        assertEquals(1, restoredRequest.realPathCount)
        assertEquals(0, restoredRequest.predictionPathCount)
    }

    private fun identityTransform() = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

    private fun frame(
        type: Int,
        revision: Long,
        contours: List<StrokeContour>,
    ) = InkStrokeFrame().also {
        it.replace(type, revision, 0L, contours)
    }

    private fun contour(left: Float, right: Float): StrokeContour {
        val top = 0f
        val bottom = 10f
        fun segment(x0: Float, y0: Float, x1: Float, y1: Float) =
            StrokeCubicSegment(
                x0, y0,
                x0 + (x1 - x0) / 3f, y0 + (y1 - y0) / 3f,
                x0 + 2f * (x1 - x0) / 3f, y0 + 2f * (y1 - y0) / 3f,
                x1, y1, 0L, 1L,
            )
        return StrokeContour(
            listOf(
                segment(left, top, right, top),
                segment(right, top, right, bottom),
                segment(right, bottom, left, bottom),
                segment(left, bottom, left, top),
            ),
            0L,
            1L,
            true,
        )
    }

    private fun emptyPredictionFrame() = ByteBuffer.allocateDirect(
        InkStrokeFrameCodec.HEADER_BYTES,
    ).order(ByteOrder.nativeOrder()).apply {
        putInt(0x4E534546)
        putInt(InkStrokeFrameCodec.VERSION)
        putInt(InkStrokeFrameCodec.PREDICTION_TYPE)
        putInt(0)
        repeat(4) { putLong(0L) }
        while (position() < InkStrokeFrameCodec.HEADER_BYTES) put(0)
    }
}
