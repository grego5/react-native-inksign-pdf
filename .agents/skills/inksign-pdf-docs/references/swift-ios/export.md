# iOS PDF export

- `finalize()` exports an immutable snapshot of committed page content.
- Live strokes, predictions, drafts, selection, and viewport state are not
  included.
- Export writes a separate output; source and working documents retain their
  current state.

- PDFKit carries source pages into the output; Quartz draws annotations and
  CoreText shapes committed text.
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
