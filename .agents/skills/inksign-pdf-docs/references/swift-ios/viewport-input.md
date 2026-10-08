# iOS viewport and input

## Viewport and modes

- `onZoomedInChange(boolean)` reports settled zoom above fitted scale with a
  0.1% tolerance. Native deduplicates results per document and reevaluates after
  page/size changes. Reporting waits 120 ms after scale/fit changes and for
  PDFView scroll/zoom gestures to finish; continuous updates stay native.

- **Mode commands:** Commands return promises and execute in the native FIFO.
  `setViewMode()` and `setInkMode()` finish text interaction and apply viewport
  options when executed. Omission preserves the viewport; an
  empty object fits; zoom and paired x/y override supplied values. `setTextMode()`
  captures its viewport request until a valid placement tap; text-only settings
  preserve the viewport. Switching modes commits a draft or cancels untapped
  placement. Finishing the text draft returns to view mode.
- **Presentation:** `PDFView` owns page display and viewport gestures; see
  [document ownership](view-lifecycle.md).
- **View mode:** PDF gestures handle navigation; admitted text touches and armed
  placement taps belong to the text overlay.
- **Edit mode:** PencilKit owns ink input. The text overlay owns text placement,
  selection, editing, and movement. PDF navigation resumes when editing ends.
- **Coordinates:** Text placement uses top-left page points in the displayed
  page orientation. `PageGeometry` maps displayed operations to canonical
  storage and confines PDFKit's media-box origin and bottom-left convention to
  adapters. Viewport focus and snapshots use current display. Editing preserves
  zoom and may pan to keep the editor and caret visible. See the shared
  [document model](../architecture.md#document-model).

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
- **Manual snapping:** Cached label rows associate nearby rules for taps above
  them. The admission band uses the displayed label line-height, with the
  existing screen-space tolerance as a minimum and measured editor line-height
  when no label is associated. Below-rule tolerance remains unchanged.
- **Text layout:** TextKit owns live wrapping, caret, and selection geometry.
  Bounded text uses one fixed physical flow rectangle in the editor and
  committed model; RTL changes logical alignment, never edge order. The model
  keeps that rectangle separate from measured visible-text bounds.
- **Layout mapping:** Committed annotations retain local bounds, flow bounds,
  and orientation. Rendering, editor activation, selection, hit testing, and
  dragging use layout-to-canonical followed by the current presentation map.
  New manual text captures displayed layout; accepted moves update coordinator
  target placement without changing a named target's source association.
- **Prepared free text:** `{ x, y, width, height }` is measured in the displayed
  page orientation and defines a fixed rectangle; x/y stay at its physical
  top-left in either direction. Alignment positions measured text inside it.
  Dimensions are hard bounds; `maxLines` caps complete lines without forcing a
  line count. `verticalAnchor` fixes the top or bottom of the block.
- **Bounded editing:** `setTextMode(options?)` applies an optional
  physical width and height from the tap toward the right and down, plus
  alignment and line options, to the live editor and committed text. Without
  dimensions it keeps auto-sized tap placement, with `maxLines` still capping
  lines. Input is accepted when complete lines fit; deletion remains available.
  Direction and font changes preserve text through reflow, even when it no
  longer fits.
- **Text direction:** Explicit LTR/RTL overrides app policy. `auto` uses the
  resolved app layout direction. Omitted direction follows the last
  `setTextDirection()` choice, or app direction when unset/`auto`. Tap placement
  captures direction when armed; editing saves it on commit. `setTextDirection()`
  also updates an active editor while retaining its fixed rectangle and
  reconciling caret visibility.

## Prepared page text
- Prepared labels are complete visual groups with exact source ranges. Lookup compares full
  token-frequency counts, preserving repeated words while allowing extracted
  word-order differences. Partial labels and substrings do not match. Rules
  are projected from immutable canonical endpoints with their original source
  identity. A vertical writing rule rejects new field insertion and focus;
  existing module text remains editable and clearable. Named focus uses the rule;
  free focus uses the target center. Empty targets reserve a
  coordinator-owned numeric ID; prepared handles retain source analysis and
  target the captured stable page through navigation. UI-owned slots and history
  outlive analysis-cache eviction; the overlay owns drafts and selection.
- Module annotation/draft values take precedence over detected embedded source
  text. Clearing removes module text only and reveals the source fallback again.
  Detection and adoption use the local rule-width/label-height band on the chosen
  side, excluding only selected label ranges; free targets use placement bounds.
  Competing annotations reject adoption. Formatting is finalized before measuring
  visible bounds, and re-resolution preserves existing formatting. See the
  [document model](../architecture.md#document-model).

## Pager direction

- `pagerDirection` controls PDFKit's page-view-controller layout independently
  of text direction. Omission and `auto` use the system semantic direction;
  explicit `ltr`/`rtl` set the PDFView semantic content attribute. PDFKit owns
  physical page gesture behavior, so exact swipe-side behavior requires runtime
  validation on supported OS versions.

- `getPageCoords()` admits in FIFO order and owns `pageCoords` mode, preserving
  the viewport. Its request captures document generation, active page ID, and
  geometry revision; the tap wait releases the command queue. UIKit distinguishes
  one in-page tap from pan/pinch; text and ink input are inactive. Completion
  returns to view mode. Page/geometry changes, mode changes, replacement, close,
  or disposal reject with `operation_cancelled`; `setViewMode()` handles Back.
