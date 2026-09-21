# iOS rendering and prediction

## Live rendering

- `InkPdfView` owns the active-page viewport and a bounded PDFium tile set.
  PDFium pixels are the only base page image; a retained transparent overlay
  supplies the `PKCanvasView` used for live ink and committed drawing display.
- PencilKit owns sampling, pressure response, smoothing, caps, joins, and
  prediction.
- Each page keeps one committed `PKDrawing`; the active canvas transaction is
  disposable. Cancellation, page changes, replacement, overlay detachment,
  and disposal discard uncommitted content.
- Page-turn previews render the target page through the retained PDFium session
  and then composite committed markup. Preview text receives a raw-PDF-to-preview
  transform; the text renderer applies canonical-to-PDF conversion once,
  including a nonzero media-box origin.
- Committed text and previews use `InkSignPdfTextRenderer` in canonical
  top-left page coordinates.
- Tiles use a page-anchored 512-by-512 device-pixel grid. Render zoom rounds
  upward to the next one-eighth step and is capped at 16; canonical tile
  coverage is `512 / (renderZoom * screenScale)`, so zoom never enlarges a
  bitmap allocation.
- At most eight tile requests are queued. Decoded tile cache cost is bounded
  at 64 MiB using exact `stride * height` byte counts and least-recently-used
  eviction; visible current and fallback tiles are protected when possible.
- Tile results carry document generation, page, quantized zoom, and render
  token identity. The serial PDFium worker checks request currency before
  rendering and main-thread installation checks it again; stale results are
  discarded while valid prior tiles remain visible beneath replacements.

## Prediction

iOS prediction remains transient until the drawing transaction reaches its final
callback and becomes committed content.
