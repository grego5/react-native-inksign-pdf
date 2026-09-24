# iOS PDF export

`finalize()` captures an immutable snapshot of committed page content. Live
strokes, predictions, drafts, selection, and viewport state remain transient.
Export writes a separate output while the caller's source and working document
retain their current state.

PDFKit carries source pages into the output document, Quartz draws page and
annotation appearances, and CoreText shapes committed text. Text annotations
are locked while remaining selectable and copyable. Signatures are locked,
read-only PDF stamp annotations with vector appearances reconstructed
approximately for the app's opaque circular pen, using its recorded variable
diameter. Unsupported PencilKit ink fails export. The reconstruction is not
pixel-identical PencilKit rendering or general brush support. Annotation locks
restrict editing in supporting viewers but do not promise copy prevention.

The exporter validates a detached output before the finalize coordinator
publishes it under the current operation. Advanced source-PDF semantics follow
the editing scope in [architecture.md](../architecture.md#scope).
