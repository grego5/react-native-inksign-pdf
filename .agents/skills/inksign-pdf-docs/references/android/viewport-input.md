# Android viewport and input

## Viewport

- UI-thread state uses displayed top-left page coordinates for focus. Transforms
  map stored content into display; ink input maps view coordinates to raw page content.
- Mode changes end core text transactions or cancel untapped placement. Text-mode viewport
  options apply after a valid tap. Session lifetime follows the shared
  [operation contract](../architecture.md#commands-and-lifetime).
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

- Shared backend projection maps source analysis into unrotated visible-box
  coordinates (CropBox intersected with MediaBox); guides are clipped to that area.
  `PageCoordinates` applies displayed rotation after this conversion.
- `PageCoordinates` maps annotation layout → canonical → display for editor,
  rendering, selection, and drag. Shared [geometry](../architecture.md#geometry-and-text-targets)
  and [export](export.md) contracts apply.
- `TextInteractionOverlay` owns placement, hit testing, editing, dragging, and
  keyboard avoidance. Placement/editor-outside drags pan; two fingers pan/pinch
  even over the editor. Viewport takeover retains text transactions/armed placement and owns
  the stream until release; manual navigation pauses caret following until text changes.
  Lifecycle cancellation consumes the retired stream through release.
  Text gestures bypass ink/page navigation.
- Final annotation construction uses the core text service with explicit
  layout/flow bounds and optional editor-measured intrinsic size. The core owns
  admitted text; editor state remains local. Publications refresh presentation.
- Same-target programmatic writes validate fonts and layout before ending the
  active editor transaction. Rejected writes preserve the draft and history.
  Captured editor formatting uses the shared opaque RGB color contract.
- Shared [bounds/line limits](../architecture.md#layout-and-editing) apply.
  Alignment and `verticalAnchor` position text inside fixed edges.
- `setMode('text')` arms placement and reports `textAdd`. A valid tap opens
  the editor on finger-up; invalid taps keep it armed. Outside taps finish editing;
  commit/cancel returns to view mode.
- Bounded editors admit fitting text. Rejection at a collapsed caret preserves
  text/caret; deletion remains available after reflow. Shorter composing replacements
  may reduce overflow; overflowing extensions preserve composition. Direction/font
  changes retain text; vertical anchor affects placement, not fit. Programmatic
  values use the same committed layout.
- Manual placement follows the shared [text layout contract](../architecture.md#layout-and-editing).
  Snap candidates load lazily from shared analysis.
  Above-rule tolerance is the greater of screen tolerance and label line-height
  (editor line-height when unlabeled); below-rule tolerance is screen-based.
  Existing annotation editing/dragging does not snap.
- Live editor height uses complete native lines within `maxLines` and flow height,
  including fallback-font metrics; committed text keeps the shared renderer layout.
- Keyboard handling changes the viewport rather than the annotation's position.
- `textDirection` updates future placement and the editor, preserving fixed
  flow bounds; reflow/caret following use the updated direction. Explicit LTR/RTL
  options win; `auto` uses app direction; omitted options use the prop default.
  An omitted prop follows app direction.
  Commit saves the resolved direction.

## Prepared page text

- PDFium analysis retains complete label glyph ranges and source rule identity.
  Lookup, values, detection/adoption, and focus follow the shared
  [document model](../architecture.md#geometry-and-text-targets).
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
- `InkStylusSampleFrame` converts real and predicted samples into the engine's
  [stylus metadata contract](../stroke-engine/input-modeling.md#boundary-and-input-admission).
  At `Down` it freezes axis availability and the view-to-raw-page rotation:
  pressure for stylus tools, tilt when the device reports `AXIS_TILT`, and
  orientation only for a directional `AXIS_ORIENTATION` range spanning `[-π, π]`.
  Finger input reports no stylus axes. A non-finite sample on an available axis
  is dropped instead of changing availability mid-stroke.
- Android `AXIS_TILT` already uses the engine convention and passes through
  clamped. Signed `AXIS_ORIENTATION` gives the tip direction clockwise from view
  up; the adapter maps the opposite tip-to-end ray through page rotation and
  wraps it into `[0, 2π)`.

- Coordinate picking uses root viewport pan/pinch routing and consumes one valid
  in-page tap. Shared [picker cancellation](../architecture.md#commands-and-lifetime)
  applies.
