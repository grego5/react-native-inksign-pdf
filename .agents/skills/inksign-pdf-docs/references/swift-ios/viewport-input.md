# iOS viewport and input

The UI thread owns viewport and interaction state. Committed ink and text use
canonical page coordinates. A native transform maps that page space through PDF
rotation into UIKit presentation.

Page navigation proceeds asynchronously after command dispatch. The coordinator
installs page imagery, the retained ink canvas, and the fitted viewport as one
switch. The current page request updates the presentation.

PencilKit owns stroke sampling, pressure response, smoothing, and prediction.
Completed drawings enter page-local history; live strokes and predictions stay
transient. The native text overlay owns editing, selection, and placement state.
Committed text annotations use canonical page coordinates and participate in
history and export.
