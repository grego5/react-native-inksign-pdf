# iOS document lifecycle

## Ownership

- `InkSignView` adapts Nitro commands and coordinates document operations.
- The document coordinator owns the PDF, ordered page records, active page ID,
  page histories, operation session, pending operation cancellation, and
  module-created artifacts.
- The serial PDF queue caches source text geometry and writing rules for both
  placement paths. The least-recently-used cache is bounded to eight pages and
  8 MiB estimated storage. Preparation normalizes source glyphs and rules into
  canonical geometry once; label rows are grouped once. Navigation, reordering,
  and presentation rotation retain analysis for stable pages. Replacement and
  disposal clear the source cache.
- Prepared handles retain immutable analysis independently of the cache. The
  coordinator retains source analysis for resolved targets to refresh free-target
  fallback after accepted placement. Page deletion releases that target state;
  replacement and disposal invalidate all handles and targets. Structural
  publication retains the document session for surviving pages.
- `PDFView` owns page presentation, viewport gestures, and overlay lifecycle.
- The page overlay provider supplies page-scoped ink canvases. The text overlay
  owns temporary editing state.

## Publication

- Follow the shared [document operation contract](../architecture.md#document-operations).
  Native promise admission is FIFO. Opening clears PDFView presentation/input
  after preceding document work finishes, then loads a module-owned working copy
  on the serial PDF queue. New-document generations are allocated at admission
  and retained through initial publication. Immediate close invalidates pending publication.
- Install only the current candidate, then resolve opening after PDFView and the
  active overlay are ready. Completion is claimed before viewport mutation;
  layout callbacks cannot reenter settlement. A current open failure leaves the view empty.
- Cancellation invalidates queued publication immediately. The PDF queue retains
  resources used by running work until cleanup can safely release them.
- Page assembly prepares and validates a detached candidate. Failed, cancelled,
  or stale mutations leave the published document intact.
- Publication updates the document, page order, active page, and structural
  dirty state together. Structural commands resolve after the active PDFKit page,
  overlay, transform, and requested viewport are ready, using the navigation gate.
  Installation retains its target page until completion; intermediate PDFKit page
  notifications do not change the coordinator selection.
- `addPages()` selects the current, first added, or last added page in the
  candidate; its result describes the page published as active.
- Stable page identity and page-local history follow pages through append,
  removal, and movement.
- `rotatePage()` updates coordinator-owned orientation and geometry revision.
  Main-thread code applies it to the in-memory PDFKit page and relayouts its presentation.
  Working bytes, source geometry, page identity, and undo/redo are retained.
  Page assembly rebinds pending orientation; [export](export.md) writes it to PDF
  metadata. Canonical target geometry and annotation local layout remain unchanged.
- Structural changes and page-content history are tracked separately.
- PDF inputs contribute pages in requested order; image inputs become PDF pages.

## Presentation and navigation

- The view maps displayed `PDFPage` objects to coordinator page IDs. The
  mapping drives page-scoped overlays and history.
- PDFKit page/view conversion aligns overlays during zoom, scrolling, and page
  changes.
- Page-change callbacks follow installed page switches.
- Disposal uses the shared operation cancellation and cleanup rules.
