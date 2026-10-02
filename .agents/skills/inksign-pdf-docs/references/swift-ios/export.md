# iOS PDF export

- `finalize()` exports an immutable snapshot of committed page content.
- Live strokes, predictions, drafts, selection, and viewport state are not
  included.
- Export writes a separate output; source and working documents retain their
  current state.

- PDFKit carries source pages into the output; Quartz draws annotations and
  CoreText shapes committed text.
- A bounded text annotation uses its fixed flow rectangle as its PDF bounds;
  measured visible text may occupy less of that rectangle.
- Text flow regions, line limits, and vertical anchors determine the same
  complete lines shown in the committed preview.
- Logical start/end alignment resolves against the saved text direction and
  places each line inside the unchanged physical flow rectangle.
- Text annotations are locked and remain selectable and copyable.
- Signatures are locked, read-only PDF stamp annotations with vector appearances
  approximating the app's opaque circular pen and recorded variable diameter.
- Unsupported PencilKit ink fails export. Signature output is not pixel-identical
  PencilKit rendering and does not support general brushes.
- Annotation locks restrict editing in supporting viewers; they do not prevent
  copying.
- Advanced source-PDF semantics follow the scope in
  [architecture.md](../architecture.md#scope).

- The exporter validates a detached output before the finalize coordinator
  publishes it for the current operation.
- Replacement and disposal cancel pending export through the
  [document operation contract](../architecture.md#document-operations).
