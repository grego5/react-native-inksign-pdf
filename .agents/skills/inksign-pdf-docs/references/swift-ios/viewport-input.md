# iOS viewport and input

- **Presentation:** `PDFView` owns page display, zoom, scrolling, and navigation.
  The document coordinator owns page identity and committed content.
- **View mode:** PDF gestures handle navigation; admitted text touches and armed
  placement taps belong to the text overlay.
- **Edit mode:** PencilKit owns ink input. The text overlay owns text placement,
  selection, editing, and movement. PDF navigation resumes when editing ends.
- **Coordinates:** PDFKit maps between page and overlay coordinates. Viewport
  movement does not change annotation geometry. Editing preserves zoom and may
  pan to keep the editor and caret visible when space permits.
- **Placement:** Without box dimensions, a tap starts a centered auto-sized
  draft and a nearby horizontal rule may set its bottom anchor. With dimensions,
  the tap is the physical rectangle's top-left corner; invalid rectangles leave
  placement armed for another tap.
- **Rule candidates:** Solid horizontal writing rules may appear anywhere on a
  page; horizontal strokes crossed by vertical table borders are excluded.
  Rows of evenly spaced dots are also supported.
- **Text layout:** TextKit owns live wrapping, caret, and selection geometry.
  Bounded text uses one fixed physical flow rectangle in the editor and
  committed model; RTL changes logical alignment, never edge order. The model
  keeps that rectangle separate from measured visible-text bounds.
- **Programmatic text:** `addTextAnnotation` commits text without opening the
  editor. `{ x, y, width, height }` defines a fixed rectangle; x/y stay at its
  physical top-left in either direction. Alignment positions measured text
  inside it. `maxLines` retains
  complete lines; `verticalAnchor` fixes the top or bottom of the visible block.
- **Bounded editing:** `insertAnnotationOn(options?)` applies an optional
  physical width and height from the tap toward the right and down, plus
  alignment and line options, to the live editor and committed text. Without
  dimensions it keeps auto-sized tap placement, with `maxLines` still capping
  lines. Input is accepted when the
  resulting complete lines fit; deletion remains available. Direction and font changes
  preserve text through reflow, even when it no longer fits.
- **Text direction:** Explicit LTR/RTL overrides app policy. `auto` uses the
  resolved app layout direction. Omitted direction follows the last
  `setTextDirection()` choice, or app direction when unset/`auto`. Save the
  resolved direction with each annotation; tap placement captures it when
  armed. Calling `setTextDirection()` also updates an active editor without
  moving its fixed rectangle at the switch; caret visibility is reconciled with
  the viewport. Save the chosen direction when editing commits.
- **History:** Draft text is temporary. Committed text and page-local ink edits
  are the content used by history and export.
