# iOS PDF export

`finalize()` captures an immutable snapshot of committed page content. Live
strokes, predictions, drafts, selection, and viewport state remain transient.
Export writes a separate output while the caller's source and working document
retain their current state.

PDFKit carries source pages into the output document, Quartz draws page and
annotation appearances, and CoreText shapes committed text. Text annotations
are locked while remaining selectable and copyable. Signature annotations are
read-only and preserve their committed variable-width shapes as vector geometry.

The exporter validates a detached output before the finalize coordinator
publishes it under the current operation. Advanced source-PDF semantics follow
the editing scope in [architecture.md](../architecture.md#scope).
