# iOS document lifecycle

## Ownership

- `InkSignView` adapts Nitro commands and coordinates document operations.
- The document coordinator owns the PDF, ordered page records, active page ID,
  page histories, operation session, pending operation cancellation, and
  module-created artifacts.
- The serial PDF queue caches source text geometry and writing rules for both
  placement paths. The least-recently-used cache is bounded to eight pages and
  8 MiB estimated storage. Page navigation does not invalidate entries; a new
  generation or disposal clears them.
- `PDFView` owns page presentation and viewport gestures.
- The page overlay provider supplies page-scoped ink canvases. The text overlay
  owns temporary editing state.

## Publication

- Follow the shared [document operation contract](../architecture.md#document-operations).
  An accepted open clears PDFView presentation and temporary input, cancels pending
  document work, and loads a module-owned working copy on the serial PDF queue.
- Install only the current candidate, then resolve opening after PDFView and the
  active overlay are ready. A current open failure leaves the view empty.
- Cancellation invalidates queued publication immediately. The PDF queue retains
  resources used by running work until cleanup can safely release them.
- Page mutations prepare and validate a detached candidate. Failed, cancelled,
  or stale mutations leave the published document intact.
- Publication updates the document, page order, active page, and structural
  dirty state together.
- `addPages()` selects the current, first added, or last added page in the
  candidate; its result describes the page published as active.
- Stable page identity and page-local history follow pages through append,
  removal, and movement.
- Structural changes and page-content history are tracked separately.
- PDF inputs contribute pages in requested order; image inputs become PDF pages.

## Presentation and navigation

- `PDFView` presents and navigates pages and reports overlay lifecycle.
- The view maps displayed `PDFPage` objects to coordinator page IDs. The
  coordinator remains authoritative for committed content and page order.
- PDFKit page/view conversion aligns overlays during zoom, scrolling, and page
  changes.
- Page-change callbacks follow installed page switches.
- Disposal uses the shared operation cancellation and cleanup rules.
- See [export.md](export.md) for finalize behavior.
