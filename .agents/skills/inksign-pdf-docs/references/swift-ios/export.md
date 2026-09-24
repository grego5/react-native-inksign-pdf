# iOS PDF export

`finalize()` exports an immutable snapshot of committed page content. It excludes
live strokes, predictions, drafts, selection, and viewport state, and writes a
separate output without changing the caller's source or working document.

Android uses PDFium. On iOS, PDFKit retains the source pages and owns the output
document, Quartz renders page and annotation appearances, and CoreText shapes
committed text. Each text annotation is locked and locked-content while
remaining selectable and copyable in supported ordinary viewers. Each signature
is a read-only, locked annotation whose appearance preserves the committed
variable-width shape as vector geometry. Neither representation is rasterized.

The detached candidate is reopened and checked for page geometry, annotation
contents, vector appearances, and persisted display, print, and lock flags. It
is published only while the finalize operation remains current. Advanced source
PDF semantics, including forms, links, outlines, layers, and existing digital
signatures, are outside the editing contract; their loss does not block export.
