# Committed markup export

- `finalize()` captures source URL, output URL, page count, and an ordered
  collection of page index, media-box geometry, rotation, generation-bound,
  deep-copied committed PencilKit drawings and immutable text-annotation
  snapshots together at the main-thread request boundary before worker scheduling.
  Text annotations remain immutable values; no UIKit editor or selection state
  crosses into the worker.
- Capture failures return a rejected `Promise<String>` so callers can handle
  before-open and disposed-view failures asynchronously. Native cache-output
  allocation failures reject as `pdf_export_failed`; `invalid_output_path` is
  reserved for a caller-controlled output contract.
- Export is read-only with respect to input and history: active or ended-but-
  unresolved drawing interactions are not cancelled or committed for export.
  The worker consumes only the captured committed page snapshots, so later
  document replacement or drawing/text changes cannot alter the request.
- PencilKit rasterization runs from the immutable captured drawing on the
  export worker; the UI-thread capture does not build an image.
- Export reserves a unique `signed-*.pdf` in the configured native cache root
  and resolves that absolute path.
- iOS export rasterizes only each transparent committed PencilKit ink layer at
  2 pixels per canonical page unit, capped at 16 million pixels per page, then
  composites it onto the corresponding original PDF page. Empty pages remain
  unchanged; the original pages are not rasterized, and their text/vector
  content is preserved. An oversized ink crop fails rather than silently
  reducing quality.
- iOS committed text is laid out with the shared Core Text renderer using
  explicit lines, natural Unicode/bidirectional shaping, canonical font size,
  canonical top-left page coordinates, and each annotation's saved text color.
  The preferred path draws selectable
  text operators directly into the PDF context. If the renderer capability
  gate cannot construct a shaped line, only a transparent text layer is
  rasterized at the fixed canonical export resolution; the source page is
  never flattened.
- Text export applies the media-box origin and top-left-to-PDF conversion in
  the export context. Viewport zoom, pan, and the temporary UIKit editor do
  not affect placement or physical font size.
- iOS placement uses the canonical page-to-PDF transform. Screen scale and
  viewport zoom do not change the exported physical ink size or resolution.
- Android preserves vector export by applying the page-coordinate transform to
  stored closed cubic contours. Each stroke may contain multiple independent
  closed subpaths; preserve the native segment order and never add bridges.
- Verify the rewritten PDF, then atomically move that exact verified artifact
  into place. Verification requires page count, order, media boxes, and
  normalized rotations to match the captured source document.
- The source path cannot equal the output path. Native cache allocation,
  writing, verification, and publication failures reject as
  `pdf_export_failed`.
- Clean `.signed-*.pdf` and `.signed-verify-*.pdf` request scratch files on
  every failure path. Never export live, predicted, or uncommitted geometry.
- Keep caller-owned source paths untouched. Native cleanup is limited to exact
  module outputs in the configured cache root; successful export does not consume,
  rename, or remove the source or the shared cache directory.
- Export is non-consuming: repeated finalization uses the same loaded source
  without altering it.
- Publication is bound to the export generation. A stale or disposed request
  retires its own reserved output, while a successful result remains readable
  until the owning view is disposed.
- Report `invalid_output_path`, `pdf_export_failed`, or `operation_cancelled`
  as appropriate.
