# iOS document lifecycle

## Ownership

- `InkSignDocumentCore` owns document FIFO, committed pages/targets/history,
  analysis, named fonts, export, and artifacts. Headless handles retain the core;
  viewer page wrappers add mode authorization and local draft precedence.
- Document state stores ordered stable page IDs and metadata. Page records hold
  geometry, content history, tags, and canonical analysis. PDFKit objects and
  active-page selection belong to `InkSignPdfViewerDocument` in the viewer.
- `ViewerInteractionCoordinator` owns modes, picking, and presentation requests.
  `ViewerViewportController` owns focus, motion, keyboard space, and settled zoom.
  The text overlay owns drafts/selection; page overlays own live PencilKit input.
- Serial PDF work returns owned candidates and analysis. Canonical analysis and
  owner-executor rotation/pair caches survive reorder and logical rotation;
  replacement/page retirement release them. Snapping and field resolution share
  the same projection.

## Publication

- Follow shared [ordering/cancellation](../architecture.md#document-operations).
  Core commands publish independently of rendering. Viewer adapters additionally
  wait for page/overlay/transform/viewport readiness.
- Open and assembly validate detached PDFium candidates before publication.
  Assembly failure preserves the published snapshot; failed open leaves no
  loaded document. Presentation failure reports an error without rolling back
  valid core data.
- Viewer imports apply current/firstAdded/lastAdded selection after publication.
  Reorder preserves the selected ID; deletion selects the neighboring page.
  Core preflight classifies removal/movement before editor suspension; queued
  execution rechecks the same policy against current page identity.
- Rotation commits logical orientation in the core, then installs PDFKit
  presentation. Existing annotations retain captured layout. Assembly preserves
  orientation; [export](export.md) persists it.
- Presentation requests are claimed before viewport writes and settle once.
  Structural suspension disables interaction; completion applies current policy.
  Core content changes refresh affected presentation; inactive-page edits leave
  the active overlay intact.

## Retirement

- Normal close drains admitted document work. Immediate cancellation/disposal
  rejects callers and prevents late publication; running worker resources remain
  owned until completion. Headless successful exports belong to the caller.
- Core publication retires replaced working files; reader leases defer deletion
  while PDFKit reads a retired snapshot. Callers do not own retirement.
  Replacement/disposal cancels modes, picking, presentation, and motion, detaches
  overlays, and releases leases. Named fonts survive viewer document replacement
  and retire with their owning core.
- Events project committed core metadata plus local viewer state. Page callbacks
  follow installed presentation; mode cleanup retires activity before callbacks.
