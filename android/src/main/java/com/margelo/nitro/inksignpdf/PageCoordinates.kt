package com.margelo.nitro.inksignpdf

import android.graphics.Matrix

/** Canonical media-box-relative, top-left content and displayed page geometry. */
internal class PageCoordinates(private val page: PdfPageDimensions) {
  val rawWidth: Double
    get() = if (page.rotation % 2 == 0) page.width else page.height

  val rawHeight: Double
    get() = if (page.rotation % 2 == 0) page.height else page.width

  private val rawToDisplayTransform: PageTransform
    get() = when (page.rotation) {
      0 -> PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
      1 -> PageTransform(0.0, 1.0, -1.0, 0.0, rawHeight, 0.0)
      2 -> PageTransform(-1.0, 0.0, 0.0, -1.0, rawWidth, rawHeight)
      3 -> PageTransform(0.0, -1.0, 1.0, 0.0, 0.0, rawWidth)
      else -> error("PDF page rotation must be a quarter turn")
    }

  fun rawToDisplay(point: PagePoint): PagePoint {
    val mapped = rawToDisplayTransform.map(point)
    return PagePoint(mapped.x, mapped.y)
  }

  fun displayToRaw(point: PagePoint): PagePoint {
    val mapped = rawToDisplayTransform.inverse().map(point)
    return PagePoint(mapped.x, mapped.y)
  }

  fun rawToDisplay(rect: PageRect): PageRect = mapRect(rect, ::rawToDisplay)

  fun displayToRaw(rect: PageRect): PageRect = mapRect(rect, ::displayToRaw)

  fun rawToView(displayToView: PageTransform): PageTransform =
    rawToDisplayTransform.then(displayToView)

  val rawPage: PdfPageDimensions get() = PdfPageDimensions(rawWidth, rawHeight)

  fun withRotation(rotation: Int): PdfPageDimensions = if (rotation % 2 == 0) {
    PdfPageDimensions(rawWidth, rawHeight, rotation)
  } else {
    PdfPageDimensions(rawHeight, rawWidth, rotation)
  }

  fun displayToRawTransform(): PageTransform = rawToDisplayTransform.inverse()

  fun canonicalToDisplay(point: PagePoint): PagePoint = rawToDisplay(point)
  fun canonicalToDisplay(rect: PageRect): PageRect = rawToDisplay(rect)
  fun displayToCanonical(point: PagePoint): PagePoint = displayToRaw(point)
  fun displayToCanonical(rect: PageRect): PageRect = displayToRaw(rect)
  fun canonicalToDisplayTransform(): PageTransform = rawToDisplayTransform
  fun layoutToCanonical(layoutPage: PdfPageDimensions?): PageTransform =
    layoutPage?.let { PageCoordinates(it).displayToRawTransform() }
      ?: PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

  fun layoutToDisplay(layoutPage: PdfPageDimensions?): PageTransform =
    layoutToCanonical(layoutPage).then(rawToDisplayTransform)

  private fun mapRect(rect: PageRect, mapPoint: (PagePoint) -> PagePoint): PageRect {
    val corners = listOf(
      PagePoint(rect.left, rect.top),
      PagePoint(rect.right, rect.top),
      PagePoint(rect.left, rect.bottom),
      PagePoint(rect.right, rect.bottom),
    ).map(mapPoint)
    return PageRect(
      left = corners.minOf { it.x },
      top = corners.minOf { it.y },
      right = corners.maxOf { it.x },
      bottom = corners.maxOf { it.y },
    )
  }
}

internal fun PageTransform.toCanvasMatrix(): Matrix = Matrix().apply {
  setValues(floatArrayOf(
    a.toFloat(), c.toFloat(), tx.toFloat(),
    b.toFloat(), d.toFloat(), ty.toFloat(),
    0f, 0f, 1f,
  ))
}
