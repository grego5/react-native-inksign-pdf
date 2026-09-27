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
- Direct insertion uses `{ x, y, width, height }`; x/y stay at the physical
  top-left in either direction, and vertical anchoring moves only visible text.
- `insertAnnotationOn(options?)` arms placement and reports `textPlacement`.
  A valid tap opens the editor on finger-up; an invalid tap leaves placement
  armed. Optional width and height make a physical rectangle from the tap
  toward the right and down; direction never changes its edges. Alignment, line
  limit, and vertical anchor affect text inside it. Preview and committed text
  show the same complete lines. Without dimensions, placement retains its
  tap-centered auto-sized behavior, with `maxLines` still limiting lines. An outside tap finishes
  editing.
- A bounded editor admits text that fits its flow region and line limit.
  Rejected input at a collapsed caret leaves text and caret in place; deletion
  remains possible after reflow. A shorter composing replacement can reduce
  overflow, while an overflowing extension preserves the existing composition.
  Direction and font-size changes retain entered text. `verticalAnchor` changes
  placement, not fit. Direct `addTextAnnotation()` clips supplied text.
- Without box dimensions, placement centers the box horizontally and aligns its
  inner bottom to the tap, subject to page clamping and rule snapping. Snap
  candidates are loaded lazily for the active page and discarded on page or
  document change.
- `setTextDirection()` updates future placement and an active editor immediately.
  Switching keeps the fixed flow rectangle in place; subsequent text edits
  reflow inside it, and caret following uses that direction.
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
