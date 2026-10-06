# Android document lifecycle

## Ownership

- `HybridInkSignView` exposes the Nitro/Fabric API and owns the document coordinator.
- The coordinator owns the working PDF, page order, active page, histories,
  dirty state, operation session, pending operation cancellation, and module-created files.
- `PdfSessionWorker` serializes PDFium sessions and document work. `SurfaceView` owns
  presentation and input; the text overlay owns draft and editor state.
- PDFium parses, assembles, renders, and exports staged PDFs.
- The app owns the `androidFallbackFont.uri` cache file. Android validates and
  reuses it before opening PDFium; when absent or invalid, it downloads the
  configured URL to a temporary sibling, validates it, and publishes it
  atomically. React preloading should also publish a complete file atomically.
  Native cleanup never removes the app's shared font file.
- Each worker-owned PDFium session caches source text geometry and writing rules
  for both placement paths. The least-recently-used cache is bounded to eight
  pages and 8 MiB estimated storage. Page navigation does not invalidate entries;
  replacing or closing the session releases them.
- Prepared handles retain canonical analysis independently of that cache.
  The coordinator retains immutable source glyphs for resolved targets so
  accepted free placement can refresh its embedded fallback after cache eviction.
  Page deletion and document replacement release the corresponding targets and
  retained glyphs. Handles keep the captured page through navigation and reordering.

## Opening

- Follow the shared [document operation contract](../architecture.md#document-operations).
  Accepting a replacement clears the old viewer, editor, navigation, and tile
  requests and cancels pending document work.
- Each open owns an attempt ID and working copy. Prepare and validate the PDFium
  candidate, resolve the optional fallback font, then wait cancellably for a
  nonzero host viewport.
- The worker owns reader lifetime. Release old readers and working files after
  their users finish; rendering-session lifetime must not keep a cancelled
  operation eligible to publish.
- Cancelling one waiting operation detaches its caller. Replacement and disposal
  perform session-wide invalidation so a targeted lookup does not stale unrelated
  tile or preview requests.
- Install the current candidate's worker session, model, and configured viewport
  as one publication. Invoke callbacks and request tiles after installation.
  Preparation or publication failure leaves the viewer empty.

## Page history and disposal

- Page identities and histories travel with pages through structural edits. Structural
  dirty state is document-level; undo and redo history is page-local.
- `rotatePage()` updates presentation orientation and geometry revision while
  retaining source geometry, working bytes, page identity, and undo/redo. Page
  assembly retains pending orientation; [export](export.md) writes it to PDF
  metadata. Cached source analysis is canonicalized at preparation and projected
  into current display for operations; rotation does not rewrite target geometry.
- `hasInk()` reads committed ink entries on the active page, so navigation,
  undo, redo, and clear are reflected directly by history.
- Reopen assembled candidates and validate page count, order, and source geometry
  before publication. Image pages use reopened metadata at PDFium's serialization
  precision; existing pages retain their presentation orientation.
- `addPages()` chooses the active page inside its detached candidate: omission or
  `current` retains the existing active page, `firstAdded` and `lastAdded` select
  the corresponding page imported by that call, and `current` selects the first
  imported page when creating a document. Empty imports do not publish a candidate.
- Clearing a page is one undoable action. Dirty state reflects committed page
  content and structural changes.
- Disposal uses the shared operation cancellation and cleanup rules; PDFium
  reader and file release remains serialized with worker access.

See [viewport-input.md](viewport-input.md) for navigation and input,
[rendering-front-buffer.md](rendering-front-buffer.md) for page and ink presentation,
and [export.md](export.md) for exported-document behavior.
