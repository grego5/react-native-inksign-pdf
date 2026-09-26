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
- `insertAnnotationOn()` arms placement and reports `textPlacement`. A valid
  page tap creates one editor on finger-up; an out-of-page tap leaves placement
  armed. A later outside-editor tap finishes editing. Failed commands return
  their errors to the caller.
- Placement centers the box horizontally and aligns its inner bottom to the
  tap, subject to page clamping. Rule snapping is loaded lazily for the active
  page and discarded on page or document change.
- Explicit text direction stays fixed. `auto` uses the IME language when
  available, otherwise the app default. RTL text switches alignment while
  present; deleting it restores the base direction. Save the effective
  direction with the annotation.
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
