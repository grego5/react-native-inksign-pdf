# iOS viewport and input

- **Field focus:** `focusPageByFieldName()` uses cached page analysis to find an
  eligible label and adjacent rule on the resolved direction's side, using the
  text-placement direction policy, then focuses the captured page's writing
  area. Newer focus or input-mode actions supersede pending focus. Document
  replacement, disposal, or target-page deletion cancels it.

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
- **Key insertion:** `insertTextByFieldName(text, key, options?)` resolves
  literal matches and rule geometry from cached page analysis on the serial PDF
  queue. It skips matches without a usable same-row rule on the resolved
  direction's side, then chooses the first (default) or last eligible match in
  page order. A missing key rejects with `text_key_not_found`; matches without
  a usable rule reject with `text_rule_not_found`. Lookup runs on the serial PDF
  queue; the main queue revalidates document generation and page ID before
  committing to the captured page, even after navigation. Replacement, page
  removal, or disposal cancels the request. An active-page commit cancels its
  live stroke and syncs the text overlay; an inactive-page commit leaves current
  input in place.
- Both field commands match multiword keys as consecutive complete words in
  extracted text, regardless of word order. Glyphs must share a visual row and
  neighboring word bounds must be within one row height. Whitespace does not
  participate in row geometry; rule selection uses the combined glyph bounds.
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
