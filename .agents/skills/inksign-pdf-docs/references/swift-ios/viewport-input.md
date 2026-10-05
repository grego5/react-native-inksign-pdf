# iOS viewport and input

## Viewport and modes

- **Mode commands:** `setViewMode()` and `setInkMode()` finish text interaction
  and apply viewport options immediately. Omission preserves the viewport; an
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
  page orientation. Existing text follows later page rotations; new text uses
  the orientation active when it is added. Viewport movement preserves page
  content geometry. Editing preserves zoom and may pan to keep the editor and
  caret visible.

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
- Prepared labels are complete contiguous visual groups. Lookup compares full
  token-frequency counts, preserving repeated words while allowing extracted
  word-order differences. Partial labels and substrings do not match. Rules
  becoming vertical after rotation are ineligible. Empty targets reserve a
  coordinator-owned numeric ID; prepared handles retain source analysis and
  target the captured stable page through navigation. UI-owned slots and history
  outlive analysis-cache eviction; the overlay owns drafts and selection.
- Module annotation/draft values take precedence over detected embedded source
  text. Clearing removes module text only and reveals the source fallback again.
  See the public API contract and Android input reference for shared semantics.

## Pager direction

- `pagerDirection` controls PDFKit's page-view-controller layout independently
  of text direction. Omission and `auto` use the system semantic direction;
  explicit `ltr`/`rtl` set the PDFView semantic content attribute. PDFKit owns
  physical page gesture behavior, so exact swipe-side behavior requires runtime
  validation on supported OS versions.
