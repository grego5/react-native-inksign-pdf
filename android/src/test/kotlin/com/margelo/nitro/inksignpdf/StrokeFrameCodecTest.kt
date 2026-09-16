package com.margelo.nitro.inksignpdf

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class StrokeFrameCodecTest {
  @Test
  fun invalidContourOffsetsFailDuringDecode() {
    assertThrows(IllegalArgumentException::class.java) {
      StrokeFrameCodec.decode(frame(segmentCount = 1, contourCount = 1, recordStart = 1))
    }
  }

  @Test
  fun invalidContourRangeFailsDuringDecode() {
    assertThrows(IllegalArgumentException::class.java) {
      StrokeFrameCodec.decode(frame(segmentCount = 1, contourCount = 1, recordCount = 2))
    }
  }

  @Test
  fun negativeCountsFailDuringDecode() {
    assertThrows(IllegalArgumentException::class.java) {
      StrokeFrameCodec.decode(frame(segmentCount = -1L))
    }
  }

  @Test
  fun reversedSourceRangesFailDuringDecode() {
    assertThrows(IllegalArgumentException::class.java) {
      StrokeFrameCodec.decode(
        frame(segmentCount = 1, contourCount = 1, sourceStart = 2L, sourceEnd = 1L),
      )
    }
  }

  @Test
  fun truncatedCubicPayloadFailsDuringDecode() {
    assertThrows(IllegalArgumentException::class.java) {
      StrokeFrameCodec.decode(
        frame(segmentCount = 1, contourCount = 1, truncatePayload = true),
      )
    }
  }

  @Test
  fun nonFiniteCubicCoordinatesFailDuringDecode() {
    assertThrows(IllegalArgumentException::class.java) {
      StrokeFrameCodec.decode(
        frame(segmentCount = 1, contourCount = 1, nonFinite = true),
      )
    }
  }

  @Test
  fun reusableTargetReplacesPreviousContents() {
    val target = StrokeFrame()
    val first = StrokeFrameCodec.decode(
      frame(segmentCount = 1, contourCount = 1), target,
    )
    assertSame(target, first)
    assertEquals(1, target.contours.size)
    assertEquals(1, target.contours.single().segments.size)

    StrokeFrameCodec.decode(frame(), target)
    assertEquals(0, target.contours.size)
  }

  @Test
  fun repeatedDecodeReusesDecoderScratch() {
    val target = StrokeFrame()
    StrokeFrameCodec.decode(frame(segmentCount = 1, contourCount = 1), target)
    StrokeFrameCodec.decode(frame(segmentCount = 1, contourCount = 1), target)
    val counters = target.decoderCounters
    val segmentGrowth = counters.segmentObjectCapacityGrowth
    val contourGrowth = counters.contourObjectCapacityGrowth
    val referencesGrowth = counters.contourSegmentReferenceCapacityGrowth

    StrokeFrameCodec.decode(frame(segmentCount = 1, contourCount = 1), target)

    assertEquals(segmentGrowth, counters.segmentObjectCapacityGrowth)
    assertEquals(contourGrowth, counters.contourObjectCapacityGrowth)
    assertEquals(referencesGrowth, counters.contourSegmentReferenceCapacityGrowth)
  }

  @Test
  fun rejectedDecodeDoesNotMutatePublishedFrame() {
    val target = StrokeFrame()
    StrokeFrameCodec.decode(frame(segmentCount = 1, contourCount = 1), target)
    val contour = target.contours.single()
    val segment = contour.segments.single()
    val originalP0X = segment.p0X

    assertThrows(IllegalArgumentException::class.java) {
      StrokeFrameCodec.decode(
        frame(segmentCount = 1, contourCount = 1, nonFinite = true), target,
      )
    }

    assertSame(contour, target.contours.single())
    assertSame(segment, target.contours.single().segments.single())
    assertEquals(originalP0X, target.contours.single().segments.single().p0X)
  }

  private fun frame(
    type: Int = StrokeFrameCodec.COMMITTED_TYPE,
    segmentCount: Long = 0L,
    contourCount: Long = 0L,
    recordStart: Long = 0L,
    recordCount: Long = 1L,
    sourceStart: Long = 0L,
    sourceEnd: Long = 1L,
    truncatePayload: Boolean = false,
    nonFinite: Boolean = false,
  ): ByteBuffer {
    val declaredSegments = segmentCount.coerceAtLeast(0L)
    val declaredContours = contourCount.coerceAtLeast(0L)
    val payloadBytes = declaredSegments * 80L + declaredContours * 40L
    val capacity = StrokeFrameCodec.HEADER_BYTES +
      if (truncatePayload) (payloadBytes - 1L).coerceAtLeast(0L) else payloadBytes
    val buffer = ByteBuffer.allocateDirect(Math.toIntExact(capacity)).order(ByteOrder.nativeOrder())
    buffer.putInt(0x4E534546)
    buffer.putInt(StrokeFrameCodec.VERSION)
    buffer.putInt(type)
    buffer.putInt(0)
    buffer.putLong(1L)
    buffer.putLong(0L)
    buffer.putLong(segmentCount)
    buffer.putLong(contourCount)
    while (buffer.position() < StrokeFrameCodec.HEADER_BYTES) buffer.put(0)
    repeat(Math.toIntExact(declaredSegments)) { index ->
      if (buffer.remaining() >= 80) {
        repeat(8) { component ->
          buffer.putDouble(if (nonFinite && component == 0) Double.NaN
            else (index * 8 + component).toDouble())
        }
        buffer.putLong(sourceStart)
        buffer.putLong(sourceEnd)
      }
    }
    repeat(Math.toIntExact(declaredContours)) {
      if (buffer.remaining() >= 40) {
        buffer.putLong(recordStart)
        buffer.putLong(recordCount)
        buffer.putLong(sourceStart)
        buffer.putLong(sourceEnd)
        buffer.putInt(1)
        buffer.putInt(0)
      }
    }
    return buffer
  }
}
