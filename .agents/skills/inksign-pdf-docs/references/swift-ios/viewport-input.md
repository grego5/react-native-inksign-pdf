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
- **Placement:** A tap starts a transient text draft. A nearby horizontal rule
  can set its bottom anchor when the tap lies within the rule's span; otherwise
  placement uses the tap. The anchor stays fixed as text grows, and bounds stay
  within the page.
- **Rule candidates:** Solid horizontal writing rules may appear anywhere on a
  page; horizontal strokes crossed by vertical table borders are excluded.
  Rows of evenly spaced dots are also supported.
- **Text layout:** TextKit owns wrapping, caret, and selection geometry. The
  editor and committed annotation share bounds, font, paragraph style, and saved
  direction.
- **History:** Draft text is temporary. Committed text and page-local ink edits
  are the content used by history and export.
