package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CubicStrokePathBuilderTest {
  @Test
  fun contourPreservesNativeCommandAndEndpointOrder() {
    val data = CubicStrokePathBuilder.buildData(contour())
    assertEquals(
      listOf(
        InkPathCommand.MOVE,
        InkPathCommand.CUBIC,
        InkPathCommand.CUBIC,
        InkPathCommand.CUBIC,
        InkPathCommand.CUBIC,
        InkPathCommand.CLOSE,
      ),
      data.commands.map { it.type },
    )
    assertEquals(0f, data.commands[0].x)
    assertEquals(0f, data.commands[0].y)
    assertEndpoint(data.commands[1], 10f, 0f)
    assertEndpoint(data.commands[2], 10f, 10f)
    assertEndpoint(data.commands[3], 0f, 10f)
    assertEndpoint(data.commands[4], 0f, 0f)
  }

  @Test
  fun discontinuousNativeContourFailsInsteadOfAddingARepairLine() {
    assertThrows(IllegalArgumentException::class.java) {
      CubicStrokePathBuilder.buildData(
        contour(listOf(segment(1f, 0f, 2f, 4f, 8f, 4f, 10f, 0f))),
      )
    }
  }

  @Test
  fun openNativeContourIsRejected() {
    assertThrows(IllegalArgumentException::class.java) {
      CubicStrokePathBuilder.buildData(contour(closed = false))
    }
  }

  private fun assertEndpoint(command: InkPathCommand, x: Float, y: Float) {
    assertEquals(x, command.x)
    assertEquals(y, command.y)
  }

  private fun contour(
    segments: List<StrokeCubicSegment> = listOf(
      segment(0f, 0f, 2f, 4f, 8f, 4f, 10f, 0f),
      segment(10f, 0f, 12f, 2f, 12f, 8f, 10f, 10f),
      segment(10f, 10f, 8f, 12f, 2f, 12f, 0f, 10f),
      segment(0f, 10f, -2f, 8f, -2f, 2f, 0f, 0f),
    ),
    closed: Boolean = true,
  ) = StrokeContour(segments, 0L, 1L, closed)

  private fun segment(vararg values: Float) = StrokeCubicSegment(
    values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7],
    0L, 1L,
  )
}
