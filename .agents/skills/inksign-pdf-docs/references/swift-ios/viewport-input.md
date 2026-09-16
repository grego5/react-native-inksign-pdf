# Viewport, modes, and input

## Viewport

- PDFView owns the presentation viewport: pan, pinch, scroll, and page display.
  The document state owns the active page.
- Viewport and mode commands run on the main thread and require a live document,
  attached active-page overlay, usable layout, and a valid transform. They
  resolve after the requested state is installed.
- `open()` and successful page switches fit and center the target page unless
  explicit viewport options are supplied. Invalid mappings are rejected as
  `view_not_ready`; work invalidated by replacement or disposal is cancelled.
- The PDFKit page-to-overlay transform is for presentation only. Ink and text
  remain in canonical media-box-relative page coordinates, so zoom and pan do
  not enter history or export.
- View mode enables PDF interaction and page navigation. Edit mode disables
  PDF interaction and presents the transparent PencilKit canvas. The viewport
  remains fixed during a stroke.
- View-mode edge navigation and page-turn previews are native presentation
  features. Preview results are identity-checked and cannot replace newer page
  state.

## Text input

- `InkSignPdfTextInteractionOverlay` owns the temporary editor, selection,
  dragging, cursor, and keyboard behavior. JavaScript receives no per-keystroke
  or coordinate stream.
- `insertAnnotationOn()` arms one in-page placement tap; the tap is converted
  once into canonical page coordinates. Empty drafts are discarded, and a
  missing selection reports `text_not_focused`.
- Text presentation styling, selection, and editor state are excluded from
  history and export. Replacement, page changes, mode changes, detachment, and
  disposal finish or cancel the same transient interaction.

## PencilKit input

- Edit mode accepts direct finger and Apple Pencil input. UIKit/PencilKit own
  sampling, pressure, smoothing, prediction, and per-sample handling.
- The coordinator maps the canvas through PDFKit conversion APIs, rejects points
  outside the page, and stores committed `PKDrawing` in canonical coordinates.
- Tool begin/end and the final drawing-change callback define one transaction.
  Cancellation restores the committed snapshot; PencilKit/UIKit undo is not
  used because native page history is the undo authority.
