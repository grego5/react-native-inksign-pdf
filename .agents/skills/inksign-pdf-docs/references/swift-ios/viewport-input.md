# iOS viewport and input

The UI thread owns viewport and interaction state. Ink and text are stored in
canonical page coordinates; one native mapping relates that page space to the
rotated PDF page and UIKit presentation. Viewport transforms never become part
of committed content.

Page navigation is asynchronous after command dispatch. The new page's PDF
imagery, retained ink canvas, and fitted viewport are installed before the
switch completes. Superseded or stale results cannot replace the current
presentation.

PencilKit owns iOS stroke sampling, pressure response, smoothing, and
prediction. Only completed drawings enter page-local history; in-progress
strokes and predictions are temporary. Text editing uses a native overlay:
editor, selection, and placement state stay transient, while committed
annotations use canonical page coordinates and participate in history and
export.
