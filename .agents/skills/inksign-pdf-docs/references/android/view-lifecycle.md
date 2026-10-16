# Android document lifecycle

## Ownership

- Shared ownership and queues: [architecture](../architecture.md#ownership-and-data-flow).
  `ViewerCanvas` owns presentation/input; `TextInteractionOverlay` owns native
  editor state. `PdfSessionWorker` serializes backend access and cleanup.
- `ViewerDocumentState` owns active-page selection and borrows core reads.
  Attachment selects the first page; import/reorder/rotation preserve identity.
  Deletion selects the former index or last survivor.
- Detach/unmount settles interaction, unsubscribes, and releases presentation,
  caches, and the exclusive viewer claim. Closing the owner detaches its viewer.
  Backend readers/files retire after their users finish.
- Prepared analysis retains rotation-zero labels, glyphs, and writing guides.
  Current rotation supplies lookup/snapping projections without a PDF rescan.
  The core retains prepared contexts; page handles reference them weakly.
  Deletion releases affected targets/contexts; owner retirement releases all.
- The worker's source-analysis LRU is bounded by eight pages and 8 MiB estimated
  storage. This backend cache is separate from retained prepared-page contexts.
- Base-raster ownership and navigation handoff:
  [rendering](rendering-front-buffer.md#pdf-pages),
  [viewport](viewport-input.md#ink-and-navigation).

## Inputs and publication

- Local files and Android content/resource URIs pass through the document loader;
  streams close after staging. Images use the shared image encoder.
- `PageInputCoordinator` owns ordered ActivityResult selection and staging on
  behalf of each core. It resolves the current React activity independently of
  the viewer; its main-thread platform lease and lifecycle observer release on
  selection/cancellation/failure. Source streams copy on IO before PDFium consumes
  owned files. Host destruction cancels waiting UI; ordinary pause preserves it.
- Selection, FIFO cancellation, filters, and empty inputs follow the shared
  [import contract](../architecture.md#import-and-export). Close blocks queued
  selection without cancelling direct or already-selected imports.
- Each open owns an operation ID and private working file. Detached reader/model
  candidates publish together; abandoned candidates retire after backend use.
- Initial import publishes before presentation installation; creation returns immediately.
  Failed opening releases its candidate without affecting another owner.
- Structural candidates validate page count/order/source geometry before
  publication. Image geometry uses reopened PDFium precision. Rotation changes
  orientation/geometry revision, preserving content identity and captured layout.
- Mutation admission, close, and cancellation:
  [command contract](../architecture.md#commands-and-lifetime).

## Fonts

- `loadFonts()` atomically publishes named static single-face TrueType sources.
  Normalized-source aliases share bytes, typeface, and private font file.
  Registry publication is on UI; loading/file retirement is on IO.
- `androidFallbackFont.uri` supports HTTP(S), local paths/files, content/resource
  URIs, Expo `file:///android_res/`, and bare resource names. Source/reconstructed
  faces are capped at 64 MiB. Streams/connections close after resolution;
  cancellation prevents publication.
- The core retains fallback bytes for structural reopen; JNI copies them into
  worker-owned storage. Named/fallback resources retire after backend users finish.
  Rendering/embedding policy: [export](export.md#text-and-fonts).

## Page history and disposal

- `PageContentHistory` is keyed by stable page ID. Permanent base plus keyed tracked
  overrides supplies rendering, lookup, and export. Shared
  [history/state policy](../architecture.md#history) defines dirty and undo semantics.
- Append new strokes/text directly. Retain inserted text identities through
  deletion and redo so later writes use the existing-target policy.
- Untracked base edits preserve unrelated redo. Tracked clear/delete masks base
  entries; undo restores them. Later base entries survive older clears.
- Core publications carry page identity and mutation deltas. Viewer retirement
  releases presentation; terminal core cleanup retires content/history.
