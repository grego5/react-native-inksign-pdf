# Viewport, modes, and input

## Contract

- Viewport and mode commands run synchronously on the main thread. They require
  a ready document, attached overlay, usable layout, and valid options; errors
  throw before the call returns.
- `open()` and successful page switches fit and center the page unless options
  override the viewport. `getViewport()` returns a usable snapshot or throws
  when the view is not ready.
- `InkPdfView.applyViewport(zoom:focus:generation:)` is the only page-view
  mutation. It accepts canonical media-box-relative focus, clamps zoom/focus,
  updates both values, calculates the page frame once, and schedules visible
  tiles once.
- The coordinator resolves a complete `ViewportTarget` before mutation: open
  defaults an omitted zoom to `1`, existing-document focus commands preserve
  the current zoom when omitted, and fit commands use the usable fit scale and
  page center.
- Page commands validate synchronously, then post the switch. Superseded or
  invalidated requests are discarded; successful switches emit `onPageChange`,
  while post-return failures are logged natively.
- Ink and text use canonical media-box-relative page coordinates across
  viewport changes.

## Text input

- `InkSignPdfTextInteractionOverlay` owns editing, selection, dragging, cursor,
  keyboard, and one-shot placement.
- Placement converts one valid tap into page coordinates. Empty drafts are
  discarded, and missing selection reports `text_not_focused`.
- History and export use committed content; presentation state remains transient.

## PencilKit input

- Edit mode accepts finger and Apple Pencil input; UIKit/PencilKit own sampling,
  pressure, smoothing, and prediction.
- Committed drawings are mapped into canonical page coordinates. Tool begin/end
  and the final drawing callback define one history transaction; cancellation
  restores the committed snapshot.
