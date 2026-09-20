package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CubicStrokePathBitmapTest {
    @Test
    fun cubicPathRendersItsControlPointBulge() {
        val data = InkPathData.fromCommands(
            listOf(
                InkPathCommand(InkPathCommand.MOVE, 20f, 100f),
                InkPathCommand(InkPathCommand.CUBIC, 140f, 100f, 50f, 10f, 110f, 10f),
                InkPathCommand(InkPathCommand.CUBIC, 20f, 100f, 110f, 190f, 50f, 190f),
                InkPathCommand(InkPathCommand.CLOSE),
            )
        )
        val bitmap = Bitmap.createBitmap(160, 220, Bitmap.Config.ARGB_8888)
        try {
            Canvas(bitmap).apply {
                drawColor(Color.WHITE)
                drawPath(data.toPath(), Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.BLACK; style = Paint.Style.FILL
                })
            }
            assertEquals(Color.BLACK, bitmap.getPixel(80, 70))
        } finally {
            bitmap.recycle()
        }
    }

    @Test
    fun completedCubicOutlineUsesRendererBatch() {
        val outline = StrokeOutline.fromCommands(
            listOf(
                InkPathCommand(InkPathCommand.MOVE, 10f, 10f),
                InkPathCommand(InkPathCommand.CUBIC, 80f, 10f, 30f, 50f, 60f, 50f),
                InkPathCommand(InkPathCommand.CLOSE),
            )
        )
        val renderer = InkRenderer()
        renderer.addCompletedOutline(outline)
        assertEquals(1, renderer.diagnostics().completedBatchCount)
        assertTrue(renderer.diagnostics().retainedSourceSegmentEstimate > 0)
    }

    @Test
    fun completedContoursRenderAsIndependentFills() {
        val outline = StrokeOutline.copyOf(overlappingOppositeContours())
        val combinedBitmap = Bitmap.createBitmap(50, 50, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(combinedBitmap)
            canvas.drawColor(Color.WHITE)
            val intentionallyBrokenCombinedPath = InkPathData.fromCommands(
                outline.contourPathData.flatMap { it.commands },
            )
            canvas.drawPath(intentionallyBrokenCombinedPath.toPath(), Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.BLACK; style = Paint.Style.FILL
            })
            assertEquals(Color.WHITE, combinedBitmap.getPixel(20, 20))
        } finally {
            combinedBitmap.recycle()
        }

        val renderer = InkRenderer()
        renderer.addCompletedOutline(outline)
        assertEquals(2L, renderer.diagnostics().retainedSourcePathCount)
        val bitmap = Bitmap.createBitmap(50, 50, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.WHITE)
            renderer.draw(canvas, 1.0, 0.0, 0.0, Color.BLACK)
            assertEquals(Color.BLACK, bitmap.getPixel(20, 20))
        } finally {
            bitmap.recycle()
        }
    }

    @Test
    fun frontBufferContoursRenderAsIndependentFills() {
        val composition = FrontBufferStrokeComposition()
        composition.reset(0L)
        composition.applyCommittedFrame(InkStrokeFrame().also {
            it.replace(
                InkStrokeFrameCodec.COMMITTED_TYPE,
                1L,
                0L,
                overlappingOppositeContours(),
            )
        })
        val request = composition.buildFrontBufferRequest(
            0L,
            1L,
            null,
            PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
            50,
            50,
            Color.BLACK,
        )
        assertEquals(2, request.realPathCount)
        val bitmap = Bitmap.createBitmap(50, 50, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.WHITE)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; style = Paint.Style.FILL }
            request.paths.forEach { canvas.drawPath(it.data.toPath(), paint) }
            assertEquals(Color.BLACK, bitmap.getPixel(20, 20))
        } finally {
            bitmap.recycle()
        }
    }

    @Test
    fun undoAndRedoRemoveAndRestoreAStrokeAcrossCompletedBatches() {
        val history = InkHistory()
        val renderer = InkRenderer()
        val preceding = StrokeOutline.fromCommands(
            listOf(
                InkPathCommand(InkPathCommand.MOVE, 5f, 5f),
                InkPathCommand(InkPathCommand.CUBIC, 10f, 5f, 6f, 6f, 9f, 6f),
                InkPathCommand(InkPathCommand.CLOSE),
            )
        )
        val multiContour = StrokeOutline.copyOf(
            listOf(
                largeClosedContour(2_048),
                largeClosedContour(1),
            )
        )

        history.append(preceding)
        renderer.addCompletedOutline(preceding)
        history.append(multiContour)
        renderer.addCompletedOutline(multiContour)
        assertEquals(3, renderer.diagnostics().completedBatchCount)
        assertEquals(3L, renderer.diagnostics().retainedSourcePathCount)
        assertEquals(2_050L, renderer.diagnostics().retainedSourceSegmentEstimate)

        val removed = history.undoMutation() as InkHistoryMutation.Removed
        renderer.removeLastCompleted(removed.outline)
        assertEquals(listOf(preceding), history.snapshot())
        assertEquals(1L, renderer.diagnostics().retainedSourcePathCount)
        assertEquals(1L, renderer.diagnostics().retainedSourceSegmentEstimate)

        val restored = history.redoMutation() as InkHistoryMutation.Appended
        renderer.addCompletedOutline(restored.outline)
        assertEquals(listOf(preceding, multiContour), history.snapshot())
        assertEquals(3L, renderer.diagnostics().retainedSourcePathCount)
        assertEquals(2_050L, renderer.diagnostics().retainedSourceSegmentEstimate)
    }

    private fun largeClosedContour(segmentCount: Int): StrokeContour {
        val segments = List(segmentCount) {
            StrokeCubicSegment(5f, 5f, 5f, 5f, 5f, 5f, 5f, 5f, 0L, 1L)
        }
        return StrokeContour(segments, 0L, 1L, true)
    }
}
