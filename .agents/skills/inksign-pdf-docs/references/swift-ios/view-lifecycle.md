# iOS document lifecycle

## Ownership

- `InkSignView` adapts Nitro and coordinates operations. Coordinator ownership:
  [architecture](../architecture.md).
- Serial PDF queue builds/caches canonical text/rule analysis and groups label
  rows once. LRU: eight pages/8 MiB estimated. Navigation/reordering/rotation
  retain analysis; replacement/disposal clear the cache.
- Handles retain immutable analysis independently; coordinator targets retain
  source analysis for fallback after movement. Page deletion releases targets.
  Structural publication retains the session for surviving pages.
- `PDFView` owns page presentation, viewport gestures, and overlay lifecycle.
- The page overlay provider supplies page-scoped ink canvases. The text overlay
  owns temporary editing state.

## Publication

- Follow shared [ordering/cancellation](../architecture.md#document-operations).
  Open clears old presentation after preceding work, then loads a working copy
  on the serial PDF queue; admission generation survives initial publication.
- Install only current candidates. Open resolves after PDFView/active-overlay
  readiness; claim completion before viewport mutation to prevent layout reentry.
- Cancellation invalidates queued publication immediately. The PDF queue retains
  resources used by running work until cleanup can safely release them.
- Page assembly prepares and validates a detached candidate. Failed, cancelled,
  or stale mutations leave the published document intact.
- Structural publication updates document/order/selection/dirty state together.
  Resolve after active page, overlay, transform, and requested viewport readiness.
  Retain target selection through intermediate PDFKit page notifications.
- Structural suspension disables interaction independently of mode; completion
  applies the latest mode. Import selection follows shared defaults.
- Rotation updates coordinator orientation/geometry revision, applies it to the
  in-memory PDFKit page, and relayouts. Assembly rebinds orientation;
  [export](export.md) persists it. Shared geometry/history invariants apply.

## Presentation and navigation

- The view maps displayed `PDFPage` objects to coordinator page IDs. The
  mapping drives page-scoped overlays and history.
- PDFKit page/view conversion aligns overlays during zoom, scrolling, and page
  changes.
- Page-change callbacks follow installed page switches.
- Disposal uses the shared operation cancellation and cleanup rules.
