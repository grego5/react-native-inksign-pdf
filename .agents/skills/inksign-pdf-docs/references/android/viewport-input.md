# Android viewport and input

## Viewport

- View and document state belong to the UI thread. Page geometry stays in
  canonical, top-left page coordinates; one transform maps it to the view.
- Mode changes commit an active text draft or cancel untapped placement.
  `setViewMode()` and `setInkMode()` apply viewport options immediately;
  `setTextMode()` applies them after a valid placement tap.
- Omitted options preserve the viewport; `{}` fits the page. Text-only options
  preserve it. Zoom is absolute; paired x/y specify canonical page focus.
  Placement zoom alone focuses the editor. Caret following and keyboard
  avoidance may pan without changing zoom. `doubleTap.zoom` belongs to double taps.
- Opening and page changes fit the page unless viewport options override it.
  Page-change events follow installation, and newer navigation requests replace
  older pending requests.

## Text

- `TextInteractionOverlay` owns text placement, hit testing, editing, dragging,
  and keyboard avoidance. Text gestures do not enter ink or page navigation.
- Direct insertion uses `{ x, y, width, height }`; x/y stay at the physical
  top-left in either direction, and vertical anchoring moves only visible text.
- `setTextMode(options?)` arms placement and reports `textPlacement`.
  A valid tap opens the editor on finger-up; an invalid tap leaves placement
  armed. Optional width and height make a physical rectangle from the tap
  toward the right and down; direction never changes its edges. Alignment, line
  limit, and vertical anchor affect text inside it. Preview and committed text
  show the same complete lines. Dimensions are hard bounds; `maxLines` is an
  additional cap, not a requested line count. An outside tap finishes editing;
  committing or cancelling the draft returns to view mode.
- A bounded editor admits text that fits its flow region and line limit.
  Rejected input at a collapsed caret leaves text and caret in place; deletion
  remains possible after reflow. A shorter composing replacement can reduce
  overflow, while an overflowing extension preserves the existing composition.
  Direction and font-size changes retain entered text. `verticalAnchor` changes
  placement, not fit. Direct `addTextAnnotation()` clips supplied text.
- Without box dimensions, placement centers the box horizontally and aligns its
  inner bottom to the tap, subject to page clamping, rule snapping, and `maxLines`.
  The active presentation loads snap candidates lazily from shared page analysis;
  see [document ownership and caching](view-lifecycle.md).
- `setTextDirection()` updates future placement and an active editor immediately.
  Switching keeps the fixed flow rectangle in place; subsequent text edits
  reflow inside it, and caret following uses that direction.
  Explicit LTR/RTL overrides app policy; `auto` uses app layout direction.
  Omission uses the last `setTextDirection()` choice, or app direction when unset.
  The resolved direction is saved when editing commits.
- Editing or dragging an existing annotation does not apply placement snapping.
  Text selection, outlines, and editing share the same page-to-view geometry.

## Field commands

- Both field commands use cached text and rule geometry on the document worker.
  They choose the first or last eligible label with a same-row rule on the
  resolved direction's side, using the text direction policy above.
- Multiword keys match consecutive complete words regardless of extracted order.
  Glyphs must share a visual row; word gaps are limited to one row height.
  Whitespace is excluded from row geometry; the combined glyph bounds locate the label.
- Missing keys reject with `text_key_not_found`; labels without a usable rule
  reject with `text_rule_not_found`. Requests capture page identity and document
  generation; replacement, target-page removal, or disposal cancels them.
- `insertTextByFieldName()` commits to the captured page even after navigation.
  The UI thread revalidates identity before mutation. Inactive-page commits
  update history and dirty state without refreshing the active presentation.
- `focusPageByFieldName()` returns to the captured page and centers its writing
  area. `enterEditMode` optionally enables ink afterward. Newer focus or mode
  requests supersede pending focus.

## Ink and navigation

- View mode owns page navigation; pan and pinch remain viewport input. RTL
  reverses page mapping.
- Edit mode accepts a single finger or stylus stroke using the transform and
  pen settings captured at stroke start.
