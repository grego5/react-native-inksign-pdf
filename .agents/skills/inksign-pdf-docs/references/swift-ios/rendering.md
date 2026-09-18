# Rendering and prediction

## Live ink

- iOS uses a transparent `PKCanvasView` supplied by the retained PDFKit page
  overlay provider. PencilKit maintains the live drawing and its presentation.
- The canvas and export rasterizer use a fixed light trait policy so configured
  opaque ink colors do not change with the app's dark-mode setting.
- Each page state keeps its committed `PKDrawing` snapshot; the coordinator
  keeps only one disposable active transaction for the retained canvas. It
  never forwards live points or a whole-history image through JavaScript.
- End, cancellation, reset, source replacement, overlay detachment, and
  disposal discard uncommitted canvas content.
- A page switch clears the retained canvas, cancels the active transaction, and
  reinstalls only the selected page's committed drawing after its overlay
  transform is valid. `InkSignPdfPageTurnLifecycle` retains a selected static
  PDF-plus-committed-markup image above PDFView until that live handoff is
  ready; it never becomes a second PDFKit page or PencilKit surface.
- PencilKit owns iOS smoothing, pressure response, caps, joins, and prediction;
  the coordinator does not rebuild those effects with the shared C++ engine.
- Committed live text, page-turn previews, and export are rendered by
  `InkSignPdfTextRenderer` from immutable page snapshots. Its Core Text
  explicit-line layout uses one top-left canonical coordinate convention and
  natural Unicode/bidirectional shaping. Preview and export never include the
  transient editor or selection outline.
- PDFKit compatibility text is extracted once during document loading into
  immutable page-local runs outside content history. A noninteractive overlay
  view renders those runs beneath PencilKit using the validated
  `pageToOverlayTransform`; page-turn preview requests carry the same runs and
  render them between the source PDF and committed markup. Universal
  ASCII/control scalars remain transparent, while non-ASCII scalars are drawn
  only when the iOS system font reports a glyph. Compatibility runs never enter
  export or content revisions.
- Android retains the page-space contour and replaceable-prediction renderer
  described by the shared stroke-engine references.

## Prediction

- iOS prediction is PencilKit-owned presentation and is never committed by the
  coordinator until the drawing transaction completes.
- Android prediction remains a replaceable native presentation suffix and stays
  outside history, replay, undo/redo, and export.
