# iOS viewport and input

## Viewport and modes

- `onZoomChange` reports settled scale/fit, deduplicated per page; initial
  presentation and page/size changes emit when ready. Wait for stable scale/fit
  and finished PDFView gestures.

- `session.setViewport()` preserves when omitted, fits for `{}`; absolute zoom
  and paired x/y override focus. Text-mode viewport options wait for a valid tap.
  Mode changes commit drafts or cancel untapped placement; finish returns to view.
  Session lifetime follows the shared [operation contract](../architecture.md#document-operations).
- `PDFView` owns viewport/navigation gestures, PencilKit owns ink, text overlay
  owns placement/selection/editing/dragging. See [ownership](view-lifecycle.md).
- `PageGeometry` confines PDFKit media-box/bottom-left coordinates to adapters;
  public focus/bounds use displayed top-left points. Editing preserves zoom and
  may pan for caret visibility. Shared [geometry](../architecture.md#document-model) applies.
- Focus positions the requested page point. Editing keeps the caret above the
  keyboard; temporary keyboard scroll space is removed when editing ends.

## Text

- **Placement:** Without box dimensions, a tap starts a centered auto-sized
  draft and a nearby horizontal rule may set its bottom anchor. With dimensions,
  the tap is the physical rectangle's top-left corner; invalid rectangles leave
  placement armed for another tap.
- **Placement viewport:** Explicit zoom is an absolute target clamped by PDFKit.
  Zoom alone focuses the editor; paired x/y override that focus. Omitted zoom
  preserves the current zoom. `doubleTap.zoom` affects only double taps.
- **Rule candidates:** Solid horizontal writing rules may appear anywhere on a
  page; horizontal strokes crossed by vertical table borders are excluded.
  Rows of evenly spaced dots are also supported.
- **Manual snapping:** Cached labels supply above-rule tolerance: max(screen
  tolerance, label line-height), editor line-height when unlabeled. Below-rule
  tolerance is screen-based.
- **Text layout:** TextKit owns live wrapping, caret, and selection geometry.
  Auto-sized editors include the empty line after a trailing newline.
  Bounded text uses one fixed physical flow rectangle in the editor and
  committed model; RTL changes logical alignment, never edge order. The model
  keeps that rectangle separate from measured visible-text bounds.
- **Layout mapping:** Rendering/editor/hit testing/dragging use captured
  layout → canonical → display. Accepted moves update target placement;
  named source association remains stable.
- **Ink input:** New page canvases inherit the viewer's interaction mode;
  the text overlay passes ink-mode touches to PencilKit.
- **Text gestures:** Touch admission identifies module text. PDFKit gestures
  yield to admitted overlay tap/long-press/drag recognition; source text remains
  selectable outside module text.
- **Bounded editing:** Shared [bounds/line limits](../architecture.md#system-boundaries)
  apply to live/committed text. Input admits complete fitting lines; deletion
  remains available. Direction/font changes retain text through overflow reflow.
  `verticalAnchor` fixes the top/bottom of the retained block.
- **Text direction:** Explicit LTR/RTL overrides app policy. `auto` uses the
  resolved app layout direction. Omitted direction follows the last
  `setTextDirection()` choice, or app direction when unset/`auto`. Tap placement
  captures direction when armed; editing saves it on commit. `setTextDirection()`
  also updates an active editor while retaining its fixed rectangle and
  reconciling caret visibility.

## Prepared page text

- PDFKit analysis groups complete visual labels with exact source ranges; rules
  retain canonical endpoints/source identity. Shared
  [lookup, values, adoption, and focus](../architecture.md#document-model) apply.
- Finalize formatting before measuring visible bounds. Cache/target lifetime:
  [ownership](view-lifecycle.md#ownership).

## Pager direction

- `pagerDirection` sets PDFView semantic direction independently of text; auto
  follows system layout. PDFKit owns physical swipes; validate supported OS behavior.

## Coordinate picking

- UIKit distinguishes an in-page tap from pan/pinch; text/ink input is inactive.
  Shared [picker lifecycle](../architecture.md#document-operations) applies.
