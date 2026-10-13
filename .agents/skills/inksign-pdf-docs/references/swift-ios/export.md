# iOS PDF export

- `finalize()` exports an immutable snapshot of committed page content and
  returns the published output as a `file://` URI. Artifact ownership uses URLs.
- Live strokes, predictions, drafts, selection, and viewport state are not
  included.
- Export writes a separate output; source and working documents retain their
  current state.
- Export applies pending page rotation to a detached PDF after verifying source
  geometry. CoreText shapes and selects lines in saved local layout, and the
  renderer maps that layout to canonical content. `PageGeometry` converts
  canonical content to PDF coordinates, including the media-box origin. Captured
  current rotation is applied once as output page metadata. PencilKit ink keeps
  its canonical content mapping; text retains its captured wrapping.

- PDFium carries source pages and annotations into the output and embeds module
  text and vector ink. CoreText supplies positioned glyphs and exact font tables;
  unsupported font instances reject export. Resources belong to one export.
- A bounded text annotation uses its fixed flow rectangle as its PDF bounds;
  measured visible text may occupy less of that rectangle.
- Text flow regions, line limits, and vertical anchors determine the same
  complete lines shown in the committed preview.
- `TextRendering.positionedLines` owns committed line selection and baselines.
  CoreText resource preparation uses those lines and retains UTF-16 clusters,
  glyph positions, captured transforms, and local clips as owned values.
- Logical start/end alignment resolves against the saved text direction and
  places each line inside the unchanged physical flow rectangle.
- Module text uses embedded glyphs with Unicode mappings and logical ActualText.
  Hard-bounded text uses isolated clipped forms; source content remains unclipped.
- Signatures use filled vector contours approximating the app's opaque circular
  pen and recorded variable diameter.
- Unsupported PencilKit ink fails export. Signature output is not pixel-identical
  PencilKit rendering and does not support general brushes.
- Advanced source-PDF semantics follow the scope in
  [architecture.md](../architecture.md#scope).

- The common writer reopens output to check geometry, vector counts, and composed
  text placement. PDFKit reopening verifies viewer interoperability, page boxes,
  and source annotation identity before publication.
- Replacement and disposal cancel pending export through the
  [document operation contract](../architecture.md#document-operations).
