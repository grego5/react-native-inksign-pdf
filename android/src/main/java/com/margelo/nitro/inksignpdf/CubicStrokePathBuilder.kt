package com.margelo.nitro.inksignpdf

import android.graphics.Path

/** Emits one native contour as one independent closed Android subpath. */
internal object CubicStrokePathBuilder {
  fun build(path: Path, contour: StrokeContour): Path {
    path.set(buildData(contour).toPath())
    return path
  }

  fun buildData(contour: StrokeContour): InkPathData {
    require(contour.closed) { "Native contour must be closed" }
    require(contour.segments.isNotEmpty()) { "Native contour must contain cubics" }
    val commands = ArrayList<InkPathCommand>(contour.segments.size + 2)
    val first = contour.segments.first()
    commands += InkPathCommand(InkPathCommand.MOVE, first.p0X, first.p0Y)
    var endpointX = first.p0X
    var endpointY = first.p0Y
    contour.segments.forEach { segment ->
      require(endpointX == segment.p0X && endpointY == segment.p0Y) {
        "Native cubic contour is discontinuous"
      }
      commands += InkPathCommand(
        InkPathCommand.CUBIC,
        segment.p3X, segment.p3Y,
        segment.c1X, segment.c1Y,
        segment.c2X, segment.c2Y,
      )
      endpointX = segment.p3X
      endpointY = segment.p3Y
    }
    require(endpointX == first.p0X && endpointY == first.p0Y) {
      "Native cubic contour closure is discontinuous"
    }
    commands += InkPathCommand(InkPathCommand.CLOSE)
    return InkPathData.fromCommands(commands)
  }
}
