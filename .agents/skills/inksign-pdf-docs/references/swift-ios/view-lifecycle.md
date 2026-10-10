# iOS document lifecycle

## Ownership

- `InkSignView` adapts Nitro, runs the FIFO command queue, and connects owners.
  Document/history ownership: [architecture](../architecture.md).
- `ViewerInteractionCoordinator` owns mode tokens, base view/ink policy,
  coordinate picking, and pending page presentation. Text activity comes from
  the overlay; input requires ready page/overlay/transform geometry.
  Mode transitions defer state snapshots until settlement; text cleanup retires
  captured activity before callbacks so newer requests retain ownership.
- `ViewerViewportController` owns programmatic viewport writes, motion,
  keyboard space, and settled zoom events. PDFKit owns its live scroll geometry.
- Serial PDF queue analyzes each original page once during open/import, before
  PDFKit serialization. Page state owns immutable canonical text/rule analysis;
  navigation, reordering, and rotation preserve it. Analysis retains no source
  PDF bytes or framework page objects.
- `getPage()` shares stored analysis through the viewer command queue; target
  fallback reads it from page state. Analysis lives with retained pages/handles.
  Page deletion releases targets; surviving pages retain their session on publication.
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
  applies the latest policy. Navigation and structural failure recovery share
  presentation readiness; requests are claimed before viewport work and settle
  once. Import selection follows shared defaults.
- Rotation updates coordinator orientation/geometry revision, applies it to the
  in-memory PDFKit page, and relayouts. Assembly rebinds orientation;
  [export](export.md) persists it. Shared geometry/history invariants apply.

## Presentation and navigation

- The view maps displayed `PDFPage` objects to coordinator page IDs. The
  mapping drives page-scoped overlays and history.
- PDFKit page/view conversion aligns overlays during zoom, scrolling, and page
  changes.
- Page-change callbacks follow installed page switches.
- Replacement/disposal retires mode callers, picking, presentation, and motion
  through the interaction owner. Running PDF work retains its FIFO slot and
  resources until completion; shared cleanup rules apply.
