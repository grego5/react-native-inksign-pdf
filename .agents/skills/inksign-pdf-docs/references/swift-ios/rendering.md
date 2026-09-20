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
- Tile and preview results carry the document generation and page identity;
  queued tile jobs check page, generation, and zoom before rendering, and stale
  results are discarded. The tile cache is bounded presentation state.

## Prediction

iOS prediction remains transient until the drawing transaction reaches its final
callback and becomes committed content.
