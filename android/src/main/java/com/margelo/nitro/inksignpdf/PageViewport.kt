package com.margelo.nitro.inksignpdf

import kotlin.math.min
import kotlin.math.abs
import kotlin.math.hypot

internal const val minPageViewportZoom = 0.1
internal const val maxPageViewportZoom = 16.0

/** A point in the canonical top-left page coordinate system, measured in PDF points. */
internal data class PagePoint(
  val x: Double,
  val y: Double,
)

/** Reusable destination for hot-path view-to-page conversion. */
internal class MutablePagePoint {
  var x: Double = 0.0
    private set
  var y: Double = 0.0
    private set

  internal fun set(x: Double, y: Double) {
    this.x = x
    this.y = y
  }

  fun isFinite(): Boolean = x.isFinite() && y.isFinite()
}

/** A point in Android view pixels. */
internal data class ViewPoint(
  val x: Double,
  val y: Double,
)

/** The drawable viewport size and the Android density used to map dp to pixels. */
internal data class ViewportSize(
  val widthPx: Double,
  val heightPx: Double,
  val density: Double,
) {
  init {
    require(widthPx.isFinite() && widthPx >= 0.0)
    require(heightPx.isFinite() && heightPx >= 0.0)
    require(density.isFinite() && density > 0.0)
  }

  val widthDp: Double get() = widthPx / density
  val heightDp: Double get() = heightPx / density
}

/** A two-dimensional affine transform with a stable, testable inverse. */
internal data class PageTransform(
  val a: Double,
  val b: Double,
  val c: Double,
  val d: Double,
  val tx: Double,
  val ty: Double,
) {
  fun map(point: PagePoint): ViewPoint {
    return ViewPoint(
      x = a * point.x + c * point.y + tx,
      y = b * point.x + d * point.y + ty,
    )
  }

  fun inverse(): PageTransform {
    val determinant = a * d - b * c
    require(determinant.isFinite() && determinant != 0.0)
    val inverseA = d / determinant
    val inverseB = -b / determinant
    val inverseC = -c / determinant
    val inverseD = a / determinant
    return PageTransform(
      a = inverseA,
      b = inverseB,
      c = inverseC,
      d = inverseD,
      tx = -(inverseA * tx + inverseC * ty),
      ty = -(inverseB * tx + inverseD * ty),
    )
  }

  /** Returns the uniform logical display scale, or null for invalid/non-uniform transforms. */
  fun uniformScale(relativeTolerance: Double = 0.001): Double? {
    val sx = hypot(a, b)
    val sy = hypot(c, d)
    val determinant = a * d - b * c
    if (!sx.isFinite() || !sy.isFinite() || sx <= 0.0 || sy <= 0.0 ||
      !determinant.isFinite() || determinant == 0.0 ||
      !relativeTolerance.isFinite() || relativeTolerance < 0.0
    ) return null
    val relativeDifference = abs(sx - sy) / maxOf(sx, sy)
    if (!relativeDifference.isFinite() || relativeDifference > relativeTolerance) return null
    return (sx + sy) / 2.0
  }

  /** Returns dp per page unit; the pixel-to-dp conversion happens exactly once here. */
  fun logicalDisplayUnitsPerPageUnit(density: Double): Double? {
    if (!density.isFinite() || density <= 0.0) return null
    val pixelsPerPageUnit = uniformScale() ?: return null
    val dpPerPageUnit = pixelsPerPageUnit / density
    return dpPerPageUnit.takeIf { it.isFinite() && it > 0.0 }
  }

}

internal data class PageViewportState(
  val zoom: Double,
  val focus: PagePoint,
  val pageToView: PageTransform,
  val viewToPage: PageTransform,
)

internal data class PageViewportTarget(
  val zoom: Double,
  val focus: PagePoint,
)

/** A validated viewport request from the public mode-transition boundary. */
internal sealed interface ViewportRequest {
  data object Preserve : ViewportRequest
  data object Fit : ViewportRequest
  data class FocusAndZoom(
    val focus: PagePoint?,
    val zoom: Double?,
  ) : ViewportRequest
}

/**
 * Owns the canonical page-to-view transform used by Android rendering and input.
 *
 * Zoom is expressed in PDF points per density-independent pixel: zoom 1 means
 * one PDF point occupies one dp. The matrices themselves operate in Android
 * view pixels, so their scale is zoom multiplied by the supplied density.
 */
internal class PageViewport(
  val page: PdfPageDimensions,
  initialSize: ViewportSize = ViewportSize(0.0, 0.0, 1.0),
) {
  init {
    require(page.width.isFinite() && page.width > 0.0)
    require(page.height.isFinite() && page.height > 0.0)
  }

  private var viewportSize = initialSize
  private var currentZoom = 1.0
  private var currentFocusX = page.width / 2.0
  private var currentFocusY = page.height / 2.0
  private var bottomInsetPx = 0.0
  private var temporaryHorizontalFocusAllowancePx = 0.0
  private var temporaryVerticalFocusAllowancePx = 0.0

  val state: PageViewportState
    get() {
      val transform = makePageToView()
      return PageViewportState(
        zoom = currentZoom,
        focus = PagePoint(currentFocusX, currentFocusY),
        pageToView = transform,
        viewToPage = transform.inverse(),
      )
    }

  val zoom: Double get() = currentZoom
  internal val focusX: Double get() = currentFocusX
  internal val focusY: Double get() = currentFocusY
  val focus: PagePoint get() = PagePoint(currentFocusX, currentFocusY)
  val size: ViewportSize get() = viewportSize

  /** Temporarily reserves the bottom of the host for the native IME. */
  fun setBottomInsetPx(value: Double) {
    val nextInset = if (value.isFinite()) {
      value.coerceIn(0.0, viewportSize.heightPx)
    } else {
      0.0
    }
    bottomInsetPx = nextInset
    preserveCurrentVerticalFocus()
    setFocusCoordinates(currentFocusX, currentFocusY)
  }

  val usableHeightPx: Double
    get() = (viewportSize.heightPx - bottomInsetPx).coerceAtLeast(0.0)

  fun setViewportSize(size: ViewportSize) {
    viewportSize = size
    bottomInsetPx = bottomInsetPx.coerceIn(0.0, size.heightPx)
    preserveCurrentHorizontalFocus()
    preserveCurrentVerticalFocus()
    setFocusCoordinates(currentFocusX, currentFocusY)
  }

  /** Returns the page-preserving zoom that fits the complete page in the viewport. */
  fun fitZoom(): Double {
    val widthZoom = viewportSize.widthDp / page.width
    val heightZoom = viewportSize.heightDp / page.height
    return clampZoom(min(widthZoom, heightZoom))
  }

  fun fit() {
    currentZoom = fitZoom()
    currentFocusX = page.width / 2.0
    currentFocusY = page.height / 2.0
    temporaryHorizontalFocusAllowancePx = 0.0
    temporaryVerticalFocusAllowancePx = 0.0
  }

  fun isFitted(): Boolean {
    return abs(currentZoom - fitZoom()) <= 0.000001 &&
      abs(currentFocusX - page.width / 2.0) <= 0.000001 &&
      abs(currentFocusY - page.height / 2.0) <= 0.000001
  }

  fun targetFor(request: ViewportRequest): PageViewportTarget? {
    return when (request) {
      ViewportRequest.Preserve -> null
      ViewportRequest.Fit -> PageViewportTarget(
        zoom = fitZoom(),
        focus = PagePoint(page.width / 2.0, page.height / 2.0),
      )
      is ViewportRequest.FocusAndZoom -> {
        val zoom = request.zoom?.let(::clampZoom) ?: currentZoom
        PageViewportTarget(
          zoom = zoom,
          focus = clampedFocus(request.focus ?: focus, zoom),
        )
      }
    }
  }

  /** Builds one edit-entry target whose horizontal focus shows the caret, not the editor center. */
  fun targetForTextEditing(
    editorCenterY: Double,
    caret: PageRect,
    zoom: Double,
    paddingPx: Double,
  ): PageViewportTarget? {
    if (!listOf(editorCenterY, caret.left, caret.right, zoom, paddingPx).all(Double::isFinite)) return null
    val base = targetFor(ViewportRequest.FocusAndZoom(
      focus = PagePoint(currentFocusX, editorCenterY),
      zoom = zoom,
    )) ?: return null
    val scale = base.zoom * viewportSize.density
    if (scale <= 0.0) return null
    val padding = paddingPx.coerceAtLeast(0.0)
    val left = (caret.left - base.focus.x) * scale + viewportSize.widthPx / 2.0
    val right = (caret.right - base.focus.x) * scale + viewportSize.widthPx / 2.0
    val adjustment = when {
      left < padding -> -(padding - left) / scale
      right > viewportSize.widthPx - padding ->
        (right - (viewportSize.widthPx - padding)) / scale
      else -> 0.0
    }
    val focusX = base.focus.x + adjustment
    temporaryHorizontalFocusAllowancePx = maxOf(
      temporaryHorizontalFocusAllowancePx,
      focusAllowancePx(focusX, page.width, viewportSize.widthPx / scale, scale),
    )
    return base.copy(focus = PagePoint(focusX, base.focus.y))
  }

  fun setViewport(zoom: Double, focus: PagePoint) {
    currentZoom = clampZoom(zoom)
    setFocusCoordinates(focus.x, focus.y)
  }

  /** Sets zoom and optionally places the requested page point at the view center. */
  fun setZoom(value: Double, focus: PagePoint? = null) {
    if (value.isFinite()) currentZoom = clampZoom(value)
    val target = focus
    if (target == null) {
      setFocusCoordinates(page.width / 2.0, page.height / 2.0)
    } else {
      setFocusCoordinates(target.x, target.y)
    }
  }

  /** Changes scale without changing the current page focus. */
  fun setZoomPreservingFocus(value: Double) {
    if (value.isFinite()) currentZoom = clampZoom(value)
  }

  /** Scales around a view point while keeping the page point beneath it stable. */
  fun zoomAround(viewPoint: ViewPoint, factor: Double) {
    zoomAround(viewPoint.x, viewPoint.y, factor)
  }

  fun zoomAround(viewX: Double, viewY: Double, factor: Double) {
    if (!factor.isFinite() || factor <= 0.0) return
    val scaleBefore = pixelsPerPagePoint()
    val anchorX = viewToPageCoordinate(viewX, viewportSize.widthPx, currentFocusX, scaleBefore)
    val anchorY = viewToPageCoordinate(viewY, usableHeightPx, currentFocusY, scaleBefore)
    currentZoom = clampZoom(currentZoom * factor)
    val scale = pixelsPerPagePoint()
    setFocusCoordinates(
      anchorX - (viewX - viewportSize.widthPx / 2.0) / scale,
      anchorY - (viewY - usableHeightPx / 2.0) / scale,
    )
  }

  /** Calculates an absolute zoom target centered on the tapped page point. */
  fun zoomTo(viewX: Double, viewY: Double, targetZoom: Double): PageViewportTarget? {
    if (!viewX.isFinite() || !viewY.isFinite() || !targetZoom.isFinite()) return null
    val target = clampZoom(targetZoom)
    if (target <= currentZoom) return null
    val tappedPoint = viewToPage(ViewPoint(viewX, viewY))
    return PageViewportTarget(
      zoom = target,
      focus = clampedFocus(tappedPoint, target),
    )
  }

  /** Places a page point at the view center, clamped to the visible page bounds. */
  fun setFocus(focus: PagePoint?) {
    val target = focus
    if (target == null) {
      setFocusCoordinates(page.width / 2.0, page.height / 2.0)
    } else {
      setFocusCoordinates(target.x, target.y)
    }
  }

  /** Scrolls in view pixels, with the page remaining within the viewport when possible. */
  fun panBy(deltaX: Double, deltaY: Double) {
    if (!deltaX.isFinite() || !deltaY.isFinite()) return
    val scale = pixelsPerPagePoint()
    setFocusCoordinates(currentFocusX + deltaX / scale, currentFocusY + deltaY / scale)
  }

  /** Applies the smallest focus change that places a canonical page rect in the usable frame. */
  fun ensurePageRectVisible(
    left: Double,
    top: Double,
    right: Double,
    bottom: Double,
    paddingPx: Double,
    includeHorizontal: Boolean = true,
  ): Boolean {
    if (!listOf(left, top, right, bottom, paddingPx).all(Double::isFinite)) return false
    val scale = pixelsPerPagePoint()
    if (scale <= 0.0) return false
    val padding = paddingPx.coerceAtLeast(0.0)
    val mappedTopLeft = pageToView(PagePoint(left, top))
    val mappedBottomRight = pageToView(PagePoint(right, bottom))
    val originalFocus = focus
    var nextFocusX = currentFocusX
    var nextFocusY = currentFocusY
    val leftAdjustment = if (mappedTopLeft.x < padding) {
      -(padding - mappedTopLeft.x) / scale
    } else 0.0
    val rightAdjustment = if (mappedBottomRight.x > viewportSize.widthPx - padding) {
      (mappedBottomRight.x - (viewportSize.widthPx - padding)) / scale
    } else 0.0
    if (includeHorizontal) {
      nextFocusX += leftAdjustment + rightAdjustment
      temporaryHorizontalFocusAllowancePx = focusAllowancePx(
        nextFocusX, page.width, viewportSize.widthPx / scale, scale,
      )
    }
    val topAdjustment = if (mappedTopLeft.y < padding) {
      -(padding - mappedTopLeft.y) / scale
    } else 0.0
    val bottomAdjustment = if (mappedBottomRight.y > usableHeightPx - padding) {
      (mappedBottomRight.y - (usableHeightPx - padding)) / scale
    } else 0.0
    nextFocusY += topAdjustment + bottomAdjustment
    temporaryVerticalFocusAllowancePx = focusAllowancePx(
      nextFocusY, page.height, usableHeightPx / scale, scale,
    )
    setFocusCoordinates(nextFocusX, nextFocusY)
    return focus != originalFocus
  }

  fun pageToView(point: PagePoint): ViewPoint {
    val scale = pixelsPerPagePoint()
    return ViewPoint(
      x = (point.x - currentFocusX) * scale + viewportSize.widthPx / 2.0,
      y = (point.y - currentFocusY) * scale + usableHeightPx / 2.0,
    )
  }

  fun viewToPage(point: ViewPoint): PagePoint {
    val scale = pixelsPerPagePoint()
    return PagePoint(
      x = viewToPageCoordinate(point.x, viewportSize.widthPx, currentFocusX, scale),
      y = viewToPageCoordinate(point.y, usableHeightPx, currentFocusY, scale),
    )
  }

  fun viewToPage(viewX: Double, viewY: Double, destination: MutablePagePoint) {
    val scale = pixelsPerPagePoint()
    destination.set(
      x = viewToPageCoordinate(viewX, viewportSize.widthPx, currentFocusX, scale),
      y = viewToPageCoordinate(viewY, usableHeightPx, currentFocusY, scale),
    )
  }

  private fun clampZoom(value: Double): Double {
    return value.coerceIn(minPageViewportZoom, maxPageViewportZoom)
  }

  private fun pixelsPerPagePoint(): Double {
    return currentZoom * viewportSize.density
  }

  private fun viewToPageCoordinate(
    viewCoordinate: Double,
    viewportLength: Double,
    focusCoordinate: Double,
    scale: Double,
  ): Double {
    return (viewCoordinate - viewportLength / 2.0) / scale + focusCoordinate
  }

  private fun setFocusCoordinates(x: Double, y: Double) {
    val candidateX = if (x.isFinite()) x else page.width / 2.0
    val candidateY = if (y.isFinite()) y else page.height / 2.0
    val clamped = clampedFocus(PagePoint(candidateX, candidateY), currentZoom)
    currentFocusX = clamped.x
    currentFocusY = clamped.y
  }

  /** Removing the IME must not pull a caret-followed page back to its old bounds. */
  private fun preserveCurrentVerticalFocus() {
    val scale = pixelsPerPagePoint()
    if (scale <= 0.0) return
    val visibleHeight = usableHeightPx / scale
    val minimum = if (visibleHeight >= page.height) page.height / 2.0 else visibleHeight / 2.0
    val maximum = if (visibleHeight >= page.height) page.height / 2.0 else page.height - minimum
    temporaryVerticalFocusAllowancePx = maxOf(
      ((minimum - currentFocusY) * scale).coerceAtLeast(0.0),
      ((currentFocusY - maximum) * scale).coerceAtLeast(0.0),
    )
  }

  private fun preserveCurrentHorizontalFocus() {
    val scale = pixelsPerPagePoint()
    if (scale <= 0.0) return
    temporaryHorizontalFocusAllowancePx = focusAllowancePx(
      currentFocusX, page.width, viewportSize.widthPx / scale, scale,
    )
  }

  private fun focusAllowancePx(
    target: Double,
    pageLength: Double,
    visibleLength: Double,
    scale: Double,
  ): Double {
    val minimum = if (visibleLength >= pageLength) pageLength / 2.0 else visibleLength / 2.0
    val maximum = if (visibleLength >= pageLength) pageLength / 2.0 else pageLength - minimum
    return maxOf((minimum - target) * scale, (target - maximum) * scale, 0.0)
  }

  private fun clampedFocus(focus: PagePoint, zoom: Double): PagePoint {
    val scale = zoom * viewportSize.density
    val visibleWidth = viewportSize.widthPx / scale
    val visibleHeight = usableHeightPx / scale
    val horizontalAllowance = temporaryHorizontalFocusAllowancePx / scale
    val verticalAllowance = temporaryVerticalFocusAllowancePx / scale
    return PagePoint(
      x = clampFocusCoordinate(focus.x, page.width, visibleWidth, horizontalAllowance),
      y = clampFocusCoordinate(
        focus.y,
        page.height,
        visibleHeight,
        verticalAllowance,
      ),
    )
  }

  private fun clampFocusCoordinate(
    value: Double,
    pageLength: Double,
    visibleLength: Double,
    allowance: Double = 0.0,
  ): Double {
    if (visibleLength >= pageLength) {
      val center = pageLength / 2.0
      if (allowance <= 0.0) return center
      return value.coerceIn(center - allowance, center + allowance)
    }
    val minimum = visibleLength / 2.0
    val maximum = pageLength - minimum
    return value.coerceIn(minimum - allowance, maximum + allowance)
  }

  private fun makePageToView(): PageTransform {
    val scale = pixelsPerPagePoint()
    return PageTransform(
      a = scale,
      b = 0.0,
      c = 0.0,
      d = scale,
      tx = viewportSize.widthPx / 2.0 - currentFocusX * scale,
      ty = usableHeightPx / 2.0 - currentFocusY * scale,
    )
  }
}
