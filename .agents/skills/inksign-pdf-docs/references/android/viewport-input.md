# Android viewport and input

## Viewport
- `onZoomedInChange(boolean)` reports settled zoom above fitted scale with a
   0.1% tolerance. Native deduplicates results per document; page/size changes
   reevaluate fit. Reporting waits for touch/navigation completion and 120 ms
   without a zoom/fit change; continuous viewport updates stay native.

- View and document state belong to the UI thread. Viewport focus uses displayed
  top-left page coordinates; transforms map stored content to that orientation.
- Mode changes commit an active text draft or cancel untapped placement.
  `setViewMode()` and `setInkMode()` apply viewport options immediately;
  `setTextMode()` applies them after a valid placement tap.
- Omitted options preserve the viewport; `{}` fits the page. Text-only options
  preserve it. Zoom is absolute; paired x/y specify displayed page focus.
  Placement zoom alone focuses the editor. Caret following and keyboard
  avoidance may pan without changing zoom. `doubleTap.zoom` belongs to double taps.
- Opening and page changes fit the page unless viewport options override it.
  Page-change events follow installation, and newer navigation requests replace
  older pending requests.
- Ink input maps from the view into raw page-content coordinates; rendering
  applies page orientation and viewport transforms.

## Text

- An annotation retains its local layout orientation and flow rectangle.
  `PageCoordinates` derives layout-to-display through layout-to-canonical;
  the editor, committed rendering, selection, and drag use that mapping.
  New text captures the current displayed orientation. Accepted placement is
  converted once at the coordinator boundary. See the shared
  [document model](../architecture.md#document-model) and [export](export.md).
- `TextInteractionOverlay` owns text placement, hit testing, editing, dragging,
  and keyboard avoidance. Text gestures do not enter ink or page navigation.
- Prepared free targets use `{ x, y, width, height }` in displayed page coordinates;
  x/y stay at the physical
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
  placement, not fit. Programmatic values use the same committed text layout.
- Without box dimensions, placement centers the box horizontally and aligns its
  inner bottom to the tap, subject to page clamping, rule snapping, and `maxLines`.
  The active presentation loads snap candidates lazily from shared page analysis.
  The above-rule snap band uses the associated label line-height, with the
  existing screen-space tolerance as a minimum and measured editor line-height
  when no label is associated. Below-rule tolerance remains unchanged; see
  [document ownership and caching](view-lifecycle.md).
- `setTextDirection()` updates future placement and an active editor immediately.
  Switching keeps the fixed flow rectangle in place; subsequent text edits
  reflow inside it, and caret following uses that direction.
  Explicit LTR/RTL overrides app policy; `auto` uses app layout direction.
  Omission uses the last `setTextDirection()` choice, or app direction when unset.
  The resolved direction is saved when editing commits.
- Editing or dragging an existing annotation does not apply placement snapping.
  Text selection, outlines, and editing share the same page-to-view geometry.

## Prepared page text
- Prepared labels are complete visual groups with exact source glyph ranges. Lookup compares full
  token-frequency counts, preserving repeated words while allowing extracted
  word-order differences. Partial labels and substrings do not match. Rules
  are selected after canonical source geometry is projected into current display.
  A vertical writing rule rejects new field insertion and focus; existing module
  text remains editable and clearable. Named focus uses the rule; free focus
  uses the target center. Empty targets reserve a
  coordinator-owned numeric ID; prepared handles retain source analysis and
  target the captured stable page through navigation. UI-owned slots and history
  outlive analysis-cache eviction; the overlay owns drafts and selection.
- Module annotation/draft values take precedence over detected embedded source
  text. Clearing removes module text only and reveals the source fallback again.
  Detection and adoption use the selected rule-width/label-height band on the
  chosen side; only the selected label glyph ranges are excluded. Free targets
  use their canonical placement region. Competing annotations reject adoption.
  Re-resolution preserves formatting; explicit formatting is finalized before
  measuring visible bounds. See the [document model](../architecture.md#document-model).

## Ink and navigation

- View mode owns page navigation; pan and pinch remain viewport input. The
  `pagerDirection` prop controls physical next/previous mapping independently
  of text direction; `auto` follows app layout direction.
- A slow horizontal drag keeps the existing distance threshold. A quick flick
  may commit after 25 dp travel at 400 dp/s when displacement and velocity agree.
  Velocity is clamped to the platform maximum; multi-touch, cancellation,
  vertical-dominant movement, and unavailable neighbors do not commit. If a
  target preview is still rendering at release, the intent waits for that preview.
- Edit mode accepts a single finger or stylus stroke using the transform and
  pen settings captured at stroke start.
