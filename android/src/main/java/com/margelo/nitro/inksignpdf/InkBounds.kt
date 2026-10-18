package com.margelo.nitro.inksignpdf

import kotlin.math.max
import kotlin.math.min

/** Immutable page-space bounds used to select and dirty front-buffer content. */
internal data class InkBounds(
  val left: Float,
  val top: Float,
  val right: Float,
  val bottom: Float,
) {
  init {
    require(left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite())
    require(left <= right && top <= bottom)
  }

  fun union(other: InkBounds): InkBounds = InkBounds(
    min(left, other.left), min(top, other.top),
    max(right, other.right), max(bottom, other.bottom),
  )

  fun intersects(other: InkBounds): Boolean =
    left < other.right && right > other.left && top < other.bottom && bottom > other.top

  fun map(transform: PageTransform): InkBounds {
    val topLeft = transform.map(PagePoint(left.toDouble(), top.toDouble()))
    val topRight = transform.map(PagePoint(right.toDouble(), top.toDouble()))
    val bottomLeft = transform.map(PagePoint(left.toDouble(), bottom.toDouble()))
    val bottomRight = transform.map(PagePoint(right.toDouble(), bottom.toDouble()))
    return InkBounds(
      minOf(topLeft.x, topRight.x, bottomLeft.x, bottomRight.x).toFloat(),
      minOf(topLeft.y, topRight.y, bottomLeft.y, bottomRight.y).toFloat(),
      maxOf(topLeft.x, topRight.x, bottomLeft.x, bottomRight.x).toFloat(),
      maxOf(topLeft.y, topRight.y, bottomLeft.y, bottomRight.y).toFloat(),
    )
  }
}
