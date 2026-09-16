# Android PDF export

`PdfExporter`:

- snapshots every page's committed ordered content, including cubic contour
  collections and text annotations, on the UI thread;
- opens a separate worker-owned PDF session;
- verifies the captured and source page counts and each page's dimensions;
- preserves every source page, its order, and its rotation;
- adds opaque vector paths for every contour in each completed stroke on its
  captured page;
  contours remain separate fill objects so overlapping opposite windings do
  not cancel. It writes path coordinates in a 256x local coordinate space and
  applies the inverse object matrix, preserving page-space fractional geometry
  through the platform PDF writer;
- adds deterministic Helvetica text objects for each committed text line,
  using canonical annotation coordinates, font size, and the annotation's
  saved text color; transient editor text and selection UI never enter the
  snapshot;
- validates the rewritten page; and
- counts source-page text objects before mutation and validates every rewritten
  page, including empty pages, against its captured dimensions, expected path
  counts, and the exact source-plus-added text-object count; and
- places each exported text object's baseline from the shared canonical
  top-edge layout, with rendered bounds—not the internal PDF matrix
  translation—being the placement contract;
- atomically replaces a unique `signed-*.pdf` reserved in the configured
  native cache root.

It never reads rolling or predicted geometry and never overwrites the source.
Export is non-consuming: the worker opens the caller-owned source read-only for
the operation, and successful export does not delete or rename it. The
`.signed-*.tmp` request scratch is allocated and retired by the cache policy on
all completion paths. Publication is bound to the requesting generation; stale
or disposed requests retire their own reserved output, while live results stay
readable until view disposal.
