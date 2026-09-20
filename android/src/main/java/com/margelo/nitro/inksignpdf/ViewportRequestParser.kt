package com.margelo.nitro.inksignpdf

/** Validated viewport options produced at the public Nitro boundary. */
internal object ViewportRequestParser {
  fun parse(options: ViewportOptions?): ViewportRequest {
    if (options == null) return ViewportRequest.Preserve
    val x = options.x
    val y = options.y
    val zoom = options.zoom
    validate(x, y, zoom)
    if (x == null && y == null && zoom == null) return ViewportRequest.Fit
    return ViewportRequest.FocusAndZoom(
      focus = x?.let { PagePoint(it, checkNotNull(y)) },
      zoom = zoom,
    )
  }

  fun parseOpen(options: ViewportOptions?): OpenViewport {
    if (options == null) return OpenViewport(focus = null, zoom = null, fitToPage = true)
    val x = options.x
    val y = options.y
    val zoom = options.zoom
    validate(x, y, zoom)
    if (x == null && y == null && zoom == null) {
      return OpenViewport(focus = null, zoom = null, fitToPage = true)
    }
    return OpenViewport(
      focus = x?.let { PagePoint(it, checkNotNull(y)) },
      zoom = zoom ?: 1.0,
      fitToPage = false,
    )
  }

  private fun validate(x: Double?, y: Double?, zoom: Double?) {
    if ((x == null) != (y == null)) {
      throw invalid("x and y must be supplied together")
    }
    if ((x != null && !x.isFinite()) || (y != null && !y.isFinite())) {
      throw invalid("x and y must be finite")
    }
    if (zoom != null && (!zoom.isFinite() || zoom <= 0.0)) {
      throw invalid("zoom must be finite and positive")
    }
  }

  private fun invalid(message: String): PdfSessionException {
    return PdfSessionException("invalid_viewport", message)
  }
}

internal class OpenViewport(
  val focus: PagePoint?,
  val zoom: Double?,
  val fitToPage: Boolean,
)
