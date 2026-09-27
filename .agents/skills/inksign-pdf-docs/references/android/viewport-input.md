# Android viewport and input

## Viewport

- View and document state belong to the UI thread. Page geometry stays in
  canonical, top-left page coordinates; one transform maps it to the view.
- Opening and page changes fit the page unless viewport options override it.
  Page-change events follow installation, and newer navigation requests replace
  older pending requests.

## Text

- `TextInteractionOverlay` owns text placement, hit testing, editing, dragging,
  and keyboard avoidance. Text gestures do not enter ink or page navigation.
- `insertAnnotationOn(options?)` arms placement and reports `textPlacement`. A
  valid page tap creates one editor on finger-up; an out-of-page tap leaves
  placement armed. With options, the tap defines the horizontal start and the
  selected top or bottom vertical edge. `xLimit` and `yLimit` define the opposite
  hard edges; `maxLines` and the region height select the first complete lines
  shown in both the live editor and the committed annotation. An invalid tap
  region leaves placement armed for another tap. Omitting options preserves the
  tap-centered editor behavior. A later `setTextDirection()` change keeps the
  current input frame in place while the next layout uses the new direction. A
  later outside-editor tap finishes editing. Failed commands return their errors
  to the caller.
- In a bounded editor, typing, paste, and ordinary replacement are admitted only
  when the complete result fits in the configured flow width, height, and
  `maxLines`. After reflow, a shorter replacement of the active composing range
  is admitted even when more deletion is needed to fit. An overflowing extension
  preserves the existing composing range. At a collapsed caret, rejected input
  leaves the text and caret in place. Deletion remains available. Ordinary
  selected text can be removed while rejecting inserted text. Direction or
  font-size reflow preserves existing text so it can be edited back into the
  region. `verticalAnchor` positions the visible block but does not affect edit
  admission. Direct `addTextAnnotation()` continues to commit and clip supplied
  text without opening an editor.
- Without flow options, placement centers the box horizontally and aligns its
  inner bottom to the tap, subject to page clamping and rule snapping. Snap
  candidates are loaded lazily for the active page and discarded on page or
  document change.
- `setTextDirection()` updates future placement and an active editor immediately.
  Switching keeps the current editor frame in place; subsequent text edits
  expand from the selected side, and caret following uses that direction.
  Explicit LTR/RTL overrides app policy; `auto` uses the current resolved app
  layout direction. The selected direction is saved when editing commits.
- Placement zoom uses `doubleTap.zoom` (default 2×) without reducing a higher
  current zoom. Editing preserves the page anchor; keyboard avoidance and caret
  following move the viewport only as needed to expose the active text.
- Editing or dragging an existing annotation does not apply placement snapping.
  Text selection, outlines, and editing share the same page-to-view geometry.

## Ink and navigation

- View mode owns page navigation; pan and pinch remain viewport input. RTL
  reverses page mapping.
- Edit mode accepts a single finger or stylus stroke using the transform and
  pen settings captured at stroke start.
