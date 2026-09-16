# Viewport, modes, and input

## Contract

- Viewport and mode commands run synchronously on the main thread. They require
  a ready document, attached overlay, usable layout, and valid options; errors
  throw before the call returns.
- `open()` and successful page switches fit and center the page unless options
  override the viewport. `getViewport()` returns a usable snapshot or throws
  when the view is not ready.
- Page commands validate synchronously, then post the switch. Superseded or
  invalidated requests are discarded silently; successful switches emit
  `onPageChange`, while post-return failures are logged natively.
- Viewport transforms are presentation-only. Ink and text stay in canonical
  media-box-relative page coordinates and therefore do not change with zoom or
  pan.

## Text input

- `InkSignPdfTextInteractionOverlay` owns editing, selection, dragging, cursor,
  keyboard, and one-shot placement. JavaScript receives no per-keystroke or
  coordinate stream.
- Placement converts one valid tap into page coordinates. Empty drafts are
  discarded, and missing selection reports `text_not_focused`.
- Presentation state is excluded from history and export. Replacement, page
  changes, mode changes, detachment, and disposal settle transient interaction.

## PencilKit input

- Edit mode accepts finger and Apple Pencil input; UIKit/PencilKit own sampling,
  pressure, smoothing, and prediction.
- Committed drawings are mapped into canonical page coordinates. Tool begin/end
  and the final drawing callback define one history transaction; cancellation
  restores the committed snapshot.
