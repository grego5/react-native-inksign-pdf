# Android PDF export

`PdfExporter` snapshots committed page history on the UI thread and writes the
result from a worker-owned PDF session. It never reads rolling or predicted
geometry and never modifies the source PDF.

- Source pages, order, dimensions, and rotations are preserved.
- Completed cubic contours are written as separate opaque vector fill paths.
  The published page-space cubics are used directly; paths are not refit or
  flattened into a bitmap.
- Committed text is written as deterministic PDF text using its canonical
  position, size, and saved color. Temporary editor and selection state is
  excluded.
- The rewritten document is checked against the captured page structure and
  expected added paths/text before publication.
- A verified result is atomically published as a unique `signed-*.pdf` in the
  native cache root. Export is non-consuming; stale or disposed requests clean
  up their own temporary and reserved outputs.
