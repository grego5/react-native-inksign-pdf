# iOS document lifecycle

## Ownership

- Shared ownership/queues: [architecture](../architecture.md#ownership-and-data-flow).
  `DocumentCore` owns document work. Document/page/text handles retain it;
  releasing a wrapper preserves other handles. Final core release schedules
  coordinator/font cleanup on the main executor; explicit close is terminal.
- Page records hold geometry, content/history, tags, and canonical analysis.
  `InkSignPdfViewerDocumentState` owns PDFKit objects and active-page selection.
  Reader leases keep its working-file snapshot alive.
- `ViewerInteractionCoordinator` owns modes, picking, and presentation requests.
  `ViewerViewportController` owns focus, motion, keyboard space, and settled zoom.
  The core owns admitted text; overlays own caret/composition/selection and live
  PencilKit input.
- Import-time PDFium analysis retains source geometry. Display projections and
  directional-pair caches survive reorder/rotation; page retirement releases them.
  Snapping and field resolution share the projection.
- Detach/unmount settles local edits, unsubscribes, and releases presentation/
  exclusive attachment without closing the core. A detached viewer retains
  configuration and empty state, with no fallback document.

## Publication

- `PageInputCoordinator` resolves a foreground key-window presenter independently
  of the viewer at presentation. None rejects `missing_presenter`; multiple reject
  `ambiguous_presenter`.
  PDF-only selection uses Files; mixed/image selection offers Files
  or ordered Photos. Picker popovers anchor to that presenter. Scene disconnect
  cancels waiting selection; ordinary backgrounding preserves it.
  Selection settles and releases its platform lease after controller dismissal;
  queued input requests therefore begin after the previous picker disappears.
- Files and explicit sources use coordinated, security-scoped copies; Photos
  copies temporary provider URLs before callbacks return and retains selection
  order. The core's FIFO waits before text settlement or structural admission.
  Open and append share PDFium assembly and candidate analysis; a single PDF
  opening retains the copy path. Shared [input contract](../architecture.md#import-and-export).
- Detached PDFium candidates validate before publication. Assembly failure
  preserves published data; presentation failure reports an error without
  rolling back valid core data.
- Core commands finish at publication. Viewer commands separately await page,
  overlay, transform, and viewport readiness.
- Import/reorder/rotation preserve selected identity; deletion selects the
  neighboring page. Core preflight rejects invalid/no-op mutations before ending
  a text transaction; queued execution rechecks current page identity.
- Rotation installs PDFKit presentation from logical core orientation. Captured
  annotation layout stays unchanged; [export](export.md) persists orientation.
- Presentation requests are claimed before viewport writes and settle once.
  Structural suspension disables interaction; completion applies current policy.
  Inactive-page edits preserve the active overlay.

## Retirement

- Close cancels waiting selection and blocks queued picker presentation while
  selected/direct imports drain. Provider callbacks retain their request-owned
  resources through completion; cancelled late copies retire without publication.
- Core text transactions end before structural/export snapshots; live ink is
  excluded. Close/admission rules: [commands](../architecture.md#commands-and-lifetime).
- Replaced working files retire after all PDFKit reader leases release them.
  Viewer replacement/disposal cancels modes, picking, presentation, and motion,
  detaches overlays, and releases leases. Fonts remain with their owning core.
- Page callbacks follow installed presentation. Mode cleanup retires activity
  before callbacks; event payloads follow the shared
  [state contract](../architecture.md#state-and-events).
