# Android document lifecycle

## Ownership

- `HybridInkSignView` owns the coordinator and exposes the Nitro/Fabric API.
  The coordinator owns working PDF and module-created files, page order, active page, histories,
  dirty state, and operation sessions/cancellation.
- `PdfSessionWorker` serializes PDFium parsing, assembly, rendering, and export.
  `SurfaceView` owns presentation/input; `TextInteractionOverlay` owns drafts
  and editor state.
- `SurfaceView` owns the shared base-raster cache. Document/structural publication
  and disposal release it; navigation and viewport changes reuse it. Navigation
  owns preview presentation through settlement and handoff; only the cache
  recycles shared bitmaps. See [rendering](rendering-front-buffer.md#pdf-pages)
  and [handoff](viewport-input.md#ink-and-navigation).
- The app owns `androidFallbackFont.uri`. Android validates/reuses it or downloads
  to a temporary sibling, validates, and publishes atomically. React preloading
  also requires atomic publication; native cleanup preserves the app's font file.
- Each worker-owned session shares text geometry/rules between placement paths.
  Its LRU cache holds at most eight pages and 8 MiB estimated storage; navigation
  retains entries, session replacement/closure releases them.
- Prepared handles retain canonical analysis and address stable pages through
  navigation/reordering. The coordinator retains target IDs and immutable source
  glyphs for embedded fallback after cache eviction. Page deletion releases
  affected targets/glyphs; close, replacement, and disposal release all of them.

## Opening

- Follow the shared [operation contract](../architecture.md#document-operations).
  Native promise admission is FIFO. Scheduling replacement/close cancels
  presentation requests; preceding document work finishes before ordinary replacement/close.
- Each open owns an attempt ID and working copy. Validate the PDFium candidate,
  resolve the optional fallback font, then wait cancellably for a nonzero viewport.
- The worker releases readers/files after their users finish. Reader lifetime
  does not authorize cancelled operations to publish.
- Targeted cancellation detaches the waiting caller without invalidating unrelated
  tile/preview work. Replacement/disposal invalidate the entire operation session.
- Publish the current worker session, model, and configured viewport atomically;
  callbacks and tile requests follow installation. Failure leaves the viewer empty.

## Page history and disposal

- Stable page identities/history survive structural edits. Undo/redo is page-local;
  structural dirty state is document-wide. Clear is one undoable action; dirty state
  reflects committed content and structural changes.
- `rotatePage()` changes presentation orientation/geometry revision while preserving
  source bytes/geometry, page identity, targets, and history. Prepared source analysis
  projects into current display; assembly retains pending orientation and
  [export](export.md) writes PDF rotation metadata.
- `hasInk()` reads active-page committed ink history, reflecting navigation,
  undo, redo, and clear.
- Reopen assembled candidates to validate page count, order, and source geometry.
  Image geometry uses reopened PDFium precision; existing pages retain orientation.
- `addPages()`: `current` (default) retains the active page; `firstAdded`/`lastAdded`
  select that call's imported page. Creating a document with `current` selects the
  first import. Selection belongs to the detached candidate; empty imports do not publish.
- Disposal follows shared cancellation/cleanup rules; worker access serializes
  PDFium reader and file release.
