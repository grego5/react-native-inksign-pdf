# iOS viewport and input

- **View mode:** `PDFView` owns pan, pinch, momentum, and page navigation.
- **Edit mode:** the page overlay owns drawing and text input; PDF navigation
  input is suspended. Verify the handoff on a device or simulator.
- Committed page coordinates remain canonical. PDFKit maps them into the visible
  page overlay.

- Page swipes use PDFView navigation.
- Imperative page commands select a stable coordinator page ID and ask PDFKit to
  present it.
- The coordinator follows the page installed by PDFKit.

- PencilKit owns stroke sampling, pressure response, smoothing, and prediction.
- Completed drawings enter page-local history; live strokes and predictions do
  not.
- The text overlay owns editing, selection, and placement state.
- TextKit lays out live text at the editor's final container width. Committed text
  retains those dimensions and shares the editor's font and paragraph style.
- Committed text uses canonical page coordinates and participates in history and
  export.
