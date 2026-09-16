# Viewport, modes, and input

## Viewport

- In view mode, PDFView owns pan, pinch, scroll, and navigation. The
  coordinator's ordered page state owns the active page; PDFView.currentPage
  and the retained overlay are presentation resources.
- enterEditMode and enterViewMode validate options before changing input:
  omitted options preserve focus and zoom, an empty object fits and centers
  the rotated page, a paired x/y focuses a clamped media-box-relative point,
  and zoom alone preserves focus. Explicit targets animate on the main thread
  for 160 ms; touch and document lifecycle changes cancel the animation.
- Commands require a live document, attached active-page overlay, usable
  layout, and a valid page transform. They resolve after mapping and mode are
  installed, not after tiles render. open() fits and centers by default and
  applies the same 0.1...16 zoom and page-bounded focus rules.
- The page-to-overlay transform is derived from PDFView.convert using three
  media-box points, cached by page/bounds/media-box identity, and rejected
  when non-finite or singular. It is presentation-only and never used for
  export. Ink and stored text remain in canonical page coordinates.
- Native double-tap zooms to its absolute target only when that target exceeds
  the current zoom. Focus is clamped to the valid scroll range, including
  unavoidable fit margins; optional edit-mode entry occurs only after the zoom
  completes and then disables the recognizer.
- A successful page switch fits and centers the target page, including revisits.
  It waits for the target overlay and transform; cancellation leaves the
  outgoing PDFView viewport unchanged. Switch IDs reject stale completions.
- View-mode edge navigation captures direction, layout direction, and
  eligibility at touch-down. It uses an 8-point dead zone, a 40-point pull
  cap, and a 30% arm distance based on captured page width. LTR/RTL reverse
  physical direction mapping; retreat, cancellation, mode changes, and
  teardown restore the outgoing presentation without switching.
- Page-turn previews capture immutable page content, source, geometry, revision,
  layout direction, and physical direction. Each direction has one preview
  slot with generation/key/instance identity; stale rendering cannot replace a
  newer slot. A committed handoff retains its selected snapshot until the live
  target overlay is ready.
- getViewport captures the main-thread viewport and returns canonical
  media-box-relative center plus absolute zoom. It rejects unusable mappings
  with view_not_ready and deferred captures invalidated by replacement or
  disposal with operation_cancelled.

## Modes

- Mode changes run on the main thread. A successful open installs view mode
  without replacing explicit initial viewport options.
- View mode enables PDF interaction and disables ink input. Edit mode disables
  PDF interaction, shows an interactive transparent PKCanvasView, and fixes
  the viewport during one direct-finger or Apple-Pencil stroke.
- Edge navigation is view-mode-only and never consumes PencilKit input.
  Leaving edit mode cancels an active stroke before navigation resumes. There
  is no native toolbar or mode UI.

## Text interaction

- InkSignPdfTextInteractionOverlay is the sole iOS text owner. It renders
  committed annotations and owns at most one native UITextView; UIKit owns
  text, selection, cursor, and keyboard state. No per-keystroke or coordinate
  data crosses the JavaScript boundary.
- Taps select/edit an annotation. Long press starts one drag transaction and
  haptic; release retains selection and commits at most one changed position,
  while cancellation restores the original. Hit testing includes the padded
  outline and a separate minimum target; presentation colors and padding are
  excluded from history and export.
- insertAnnotationOn validates the ready presentation, settles editing,
  preserves the viewport, and arms one placement tap. Only an in-page tap is
  accepted; it is mapped through PDFKit once and creates one editor centered
  at the clamped canonical point. insertAnnotationOff clears only pending
  placement. A non-tap or out-of-page touch remains ordinary PDF interaction.
- The editor follows the caret by the minimum shared PDFView viewport delta.
  Keyboard avoidance adds only the occluded area when enabled; disabling it
  does not disable ordinary caret following. Existing text uses first-strong
  direction; empty text uses the input-mode or locale hint. Empty drafts are
  discarded, and missing selection rejects with text_not_focused.
- Replacement, page change, mode change, overlay detachment, and disposal use
  the same text-finish path. Source PDF form controls are not imported or
  edited.

## PencilKit input

- Edit mode accepts direct finger and Apple Pencil input only. UIKit/PencilKit
  own sample conversion, pressure, smoothing, prediction, and per-sample
  handling; JavaScript receives none of them.
- The coordinator maps canvas geometry through public PDFKit conversion APIs,
  rejects points outside the supported media box, and stores committed
  PKDrawing in canonical page coordinates. Zoom and pan never enter history or
  export, and committed ink survives overlay recreation.
- Tool begin/end callbacks define one interaction transaction. The transaction
  remains the owner until PencilKit's final drawing-change callback commits one
  history action; new input is gated until that callback resolves.
- PencilKit does not attach a transaction ID to the final drawing-change
  callback, so the ended-state gate is required; it does not infer completion from main-queue timing.
- Cancellation invalidates the transaction, resets the recognizer, and
  restores the committed snapshot. The canonical snapshot stacks are the sole
  undo authority; PencilKit/UIKit undo is disabled.
