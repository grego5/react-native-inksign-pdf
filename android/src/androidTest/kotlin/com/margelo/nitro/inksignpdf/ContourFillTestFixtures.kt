package com.margelo.nitro.inksignpdf

internal fun overlappingOppositeContours(): List<StrokeContour> = listOf(
  StrokeContour(listOf(
    StrokeCubicSegment(30f, 20f, 30f, 25.52f, 25.52f, 30f, 20f, 30f, 0L, 1L),
    StrokeCubicSegment(20f, 30f, 14.48f, 30f, 10f, 25.52f, 10f, 20f, 0L, 1L),
    StrokeCubicSegment(10f, 20f, 10f, 14.48f, 14.48f, 10f, 20f, 10f, 0L, 1L),
    StrokeCubicSegment(20f, 10f, 25.52f, 10f, 30f, 14.48f, 30f, 20f, 0L, 1L),
  ), 0L, 1L, true),
  StrokeContour(listOf(
    StrokeCubicSegment(20f, 12f, 19f, 12f, 18f, 14f, 18f, 16f, 0L, 1L),
    StrokeCubicSegment(18f, 16f, 18f, 24f, 19f, 28f, 20f, 28f, 0L, 1L),
    StrokeCubicSegment(20f, 28f, 21f, 28f, 22f, 24f, 22f, 16f, 0L, 1L),
    StrokeCubicSegment(22f, 16f, 22f, 14f, 21f, 12f, 20f, 12f, 0L, 1L),
  ), 0L, 1L, true),
)

internal fun overlappingOppositePathData(): List<InkPathData> =
  overlappingOppositeContours().map(CubicStrokePathBuilder::buildData)
