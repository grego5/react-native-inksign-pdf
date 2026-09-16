# iOS rendering and prediction

## Live rendering

- PDFKit presents the source page. A retained page overlay supplies the
  transparent `PKCanvasView` used for live ink and committed drawing display.
- PencilKit owns sampling, pressure response, smoothing, caps, joins, and
  prediction. The shared C++ stroke engine is not used to redraw iOS ink.
- Each page keeps one committed `PKDrawing`; the active canvas transaction is
  disposable. Cancellation, page changes, replacement, overlay detachment,
  and disposal discard uncommitted content.
- Page-turn previews are temporary images of the source page plus committed
  markup. They do not become PDFKit pages or additional PencilKit canvases.
- Committed text and previews use `InkSignPdfTextRenderer` in canonical
  top-left page coordinates. The temporary editor and selection outline are
  never rendered into previews or exports.
- PDFKit compatibility text is extracted during load and displayed in a
  noninteractive overlay below the canvas. It is presentation-only and is not
  part of history or export.

## Prediction

iOS prediction is PencilKit presentation only. It is excluded from history and
export and becomes committed content only when the drawing transaction reaches
its final callback.

