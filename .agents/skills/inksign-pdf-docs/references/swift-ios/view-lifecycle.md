# iOS document lifecycle

## Ownership

- `InkSignView` adapts Nitro commands and coordinates document operations.
- The document coordinator owns the published PDF, ordered page records, active
  page ID, page histories, generation, and module-created artifacts.
- `PDFView` owns page presentation and viewport gestures.
- The page overlay provider supplies page-scoped ink canvases. The text overlay
  owns temporary editing state.

## Publication

- Opening copies the caller's PDF into a module-owned working document.
- Opening prepares a detached candidate while the current presentation remains
  usable. A current open failure clears the published document before rejection;
  a stale attempt cannot alter a newer open.
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
- Disposal invalidates pending operations and releases document, worker, and
  presentation resources.
- See [export.md](export.md) for finalize behavior.
