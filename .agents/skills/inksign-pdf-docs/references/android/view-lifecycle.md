# Android document lifecycle

## Ownership

- `HybridInkSignView` owns the coordinator/API. Shared document, target, and
  session ownership: [architecture](../architecture.md).
- `PdfSessionWorker` serializes PDFium parsing, assembly, rendering, and export.
  `SurfaceView` owns presentation/input; `TextInteractionOverlay` owns drafts
  and editor state.
- `SurfaceView` owns/recycles the base-raster cache; navigation borrows previews.
  Document/structural publication and disposal release it; navigation/viewport
  changes reuse it. See [rendering](rendering-front-buffer.md#pdf-pages)
  and [handoff](viewport-input.md#ink-and-navigation).
- The app owns `androidFallbackFont.uri`. Android validates/reuses it or downloads
  to a temporary sibling, validates, and publishes atomically. React preloading
  also requires atomic publication; native cleanup preserves the app's font file.
- Each worker-owned session shares text geometry/rules between placement paths.
  Its LRU cache holds at most eight pages and 8 MiB estimated storage; navigation
  retains entries, session replacement/closure releases them.
- Handles retain analysis; coordinator targets retain source glyphs for fallback
  after eviction. Page deletion releases affected targets/glyphs; document
  teardown releases all.

## Opening

- Follow shared [ordering/cancellation](../architecture.md#document-operations).
- Each open owns an attempt ID and working copy. Validate the PDFium candidate,
  resolve the optional fallback font, then wait cancellably for a nonzero viewport.
- Worker cleanup releases readers/files after their users finish.
- Targeted cancellation detaches the waiting caller without invalidating unrelated
  tile/preview work. Replacement/disposal invalidate the entire operation session.
- Publish the current worker session, model, and configured viewport atomically;
  callbacks and tile requests follow installation. Failure leaves the viewer empty.

## Page history and disposal

- Histories follow stable page IDs; structural dirty state is separate from
  page-content history. Clear/clearInk are undoable page-local edits.
- Rotation updates orientation/geometry revision while preserving source and
  content identity. Assembly retains orientation; [export](export.md) persists it.
- `clearInk()` cancels live ink; `hasInk()` reads committed active-page ink.
- Reopen assembled candidates to validate page count, order, and source geometry.
  Image geometry uses reopened PDFium precision; existing pages retain orientation.
- Import selection belongs to the detached candidate; shared
  [import defaults](../architecture.md#system-boundaries) apply.
- Disposal follows shared cancellation/cleanup rules; worker access serializes
  PDFium reader and file release.
