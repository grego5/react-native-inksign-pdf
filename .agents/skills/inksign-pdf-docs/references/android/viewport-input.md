# Android viewport and input

## Viewport

- UI-thread state uses displayed top-left page coordinates for focus. Transforms
  map stored content into display; ink input maps view coordinates to raw page content.
- Mode changes commit drafts or cancel untapped placement. Text-mode viewport
  options apply after a valid tap. Session lifetime follows the shared
  [operation contract](../architecture.md#document-operations).
- `session.setViewport()` preserves the viewport; `{}` fits; text-only options preserve it.
  Zoom is absolute; paired x/y set page focus. Placement zoom alone focuses the
  editor. Caret/keyboard handling may pan without zooming; `doubleTap.zoom`
  controls double taps.
- Open/page changes fit unless viewport options override. Page callbacks follow
  installation; newer navigation requests replace pending ones.
- `onZoomChange` reports settled scale/fit, deduplicated per page; initial
  presentation and page/size changes emit when ready. Wait for touch/navigation
  completion and stable zoom/fit.

## Text

- `PageCoordinates` maps annotation layout → canonical → display for editor,
  rendering, selection, and drag. Shared [geometry](../architecture.md#document-model)
  and [export](export.md) contracts apply.
- `TextInteractionOverlay` owns placement, hit testing, editing, dragging, and
  keyboard avoidance. Placement/editor-outside drags pan; two fingers pan/pinch
  even over the editor. Viewport takeover retains drafts/armed placement and owns
  the stream until release; manual navigation pauses caret following until text changes.
  Lifecycle cancellation consumes the retired stream through release.
  Text gestures bypass ink/page navigation.
- Shared [bounds/line limits](../architecture.md#system-boundaries) apply.
  Alignment and `verticalAnchor` position text inside fixed edges.
- `setMode('text')` arms placement and reports `textAdd`. A valid tap opens
  the editor on finger-up; invalid taps keep it armed. Outside taps finish editing;
  commit/cancel returns to view mode.
- Bounded editors admit fitting text. Rejection at a collapsed caret preserves
  text/caret; deletion remains available after reflow. Shorter composing replacements
  may reduce overflow; overflowing extensions preserve composition. Direction/font
  changes retain text; vertical anchor affects placement, not fit. Programmatic
  values use the same committed layout.
- Auto-sized placement centers horizontally with inner bottom at the tap, then
  clamps/snaps to the page/rules. Snap candidates load lazily from shared analysis.
  Above-rule tolerance is the greater of screen tolerance and label line-height
  (editor line-height when unlabeled); below-rule tolerance is screen-based.
  Existing annotation editing/dragging does not snap.
- `setTextDirection()` updates future placement and the editor, preserving fixed
  flow bounds; reflow/caret following use the updated direction. Explicit LTR/RTL
  wins; `auto` uses app direction; omission uses the last setting or app direction.
  Commit saves the resolved direction.

## Prepared page text

- PDFium analysis retains complete label glyph ranges and source rule identity.
  Lookup, values, detection/adoption, and focus follow the shared
  [document model](../architecture.md#document-model).
- Project source rules into current display before selection; finalize formatting
  before measuring visible bounds. [Cache/target lifetime](view-lifecycle.md#ownership).

## Ink and navigation

- View mode admits page pulls at content edges; pan/pinch remain viewport input.
  `pagerDirection` controls physical next/previous mapping independently of text;
  `auto` follows app direction.
- Distance threshold is 30% of visible page width; flicks may commit after 25 dp
  at 400 dp/s with agreeing displacement/velocity. Clamp velocity to platform
  maximum. Multi-touch, cancellation, vertical-dominant motion, or missing neighbors
  cannot commit.
- A pull owns the stream through release/cancel and follows the finger while its
  chosen preview loads. Neutral retains the gesture; reversal requests the other
  neighbor. Release waits for a loading preview; failure settles back to source.
- Touch during committed settlement stops animation, installs the destination
  once, and captures a new gesture there; during snap-back it uses the source.
  Tile handoff is independent and cannot block/reset the newer gesture.
- Handoff metadata retires after complete current tile coverage is drawn and
  acknowledged: hardware Android 10+ uses frame commit; older/software rendering
  uses the next frame. Recheck document/page/switch ID, coverage revision, and
  completeness. Readiness requests drawing; frame commit confirms submission,
  not physical presentation. See [base fallback/tiles](rendering-front-buffer.md#pdf-pages).
- Ink uses one finger or stylus with transform/pen settings captured at stroke start.
  A second finger cancels finger ink and owns viewport pan/pinch until all lift;
  stylus retains drawing ownership. Page/mode/lifecycle changes cancel viewport
  input and consume the retired stream through release.

- Coordinate picking uses root viewport pan/pinch routing and consumes one valid
  in-page tap. Shared [picker cancellation](../architecture.md#document-operations)
  applies; Android detach also cancels the request.
