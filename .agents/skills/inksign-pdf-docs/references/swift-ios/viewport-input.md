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
- **Text layout:** TextKit owns live wrapping, caret, and selection geometry.
  Bounded text uses one fixed physical flow rectangle in the editor and
  committed model; RTL changes logical alignment, never edge order. The model
  keeps that rectangle separate from measured visible-text bounds.
- **Programmatic text:** `insertTextAt()` commits text without opening the
  editor. `{ x, y, width, height }` is measured in the displayed page
  orientation and defines a fixed rectangle; x/y stay at its physical top-left
  in either direction. Alignment positions measured text inside it. Dimensions
  are hard bounds; `maxLines` caps complete lines without forcing a line count.
  `verticalAnchor` fixes the top or bottom of the block.
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

## Field commands

- Both commands search cached source text and rules on the serial PDF queue.
  Source geometry is projected into displayed page coordinates before pairing.
  They choose the first or last eligible label with a horizontal same-row rule
  on the resolved direction's side, using the text direction policy above.
  Rules that become vertical after rotation are ineligible.
- Multiword keys match consecutive complete words regardless of extracted order.
  Glyphs share a visual row; word gaps are limited to one row height. Whitespace
  is excluded from row geometry; combined glyph bounds locate the label.
- Missing keys reject with `text_key_not_found`; labels without a usable rule
  reject with `text_rule_not_found`. The main queue revalidates document
  generation, page ID, and geometry revision before applying results.
  Replacement, disposal, target-page deletion, or rotation cancels stale results
  with `operation_cancelled`.
- `insertTextByFieldName()` commits to the captured page after navigation.
  Insertion bounds and vertical anchors use displayed geometry; new text is upright.
  Active-page commits cancel live ink and sync the text overlay; inactive-page
  commits retain current input.
- `focusPageByFieldName()` returns to the captured page. `verticalAnchor`
  defaults to `center`; `top` and `bottom` place the rule inward from that
  viewport edge by `edgeOffset` page points. Offset defaults to zero and caps
  at half the visible height; displayed page bounds constrain focus. The final
  focus point converts to PDFKit page coordinates. `setInkMode: true`
  enables ink after focus. Newer focus or mode actions supersede pending focus.
