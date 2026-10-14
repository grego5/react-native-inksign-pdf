# 12 - Attach viewer presentation through document changes

[Plan](../TASKS.md)

Status: Complete (implementation and applicable simulator checks)
Complexity: High
Depends on: 11

## Objective and non-goals

Make the viewer a core client and presentation owner. Retain PDFKit, existing
interaction/viewport coordination, native editing, and user-visible readiness
contracts. Do not create a new renderer, document queue, or React mirror registry.

## Read before editing

- Android `HybridInkSignView.kt`: documentChanged and adapter commands;
  `ViewerDocumentState.kt`: active selection separate from core metadata.
- `ios/InkSignView.swift`, `InkSignView+Document.swift`,
  `InkSignView+MutablePages.swift`, `InkSignView+PageNavigation.swift`,
  `DocumentCandidateLoader.swift`, and `History.swift`.
- `ios/ViewerInteractionCoordinator.swift`, `PageOverlay.swift`,
  `PageInputCoordinator.swift`, and `TextCommands.swift`.
- Core/handles from Tasks 09-11; current viewer event/mode specs.
- Maintainer iOS lifecycle, viewport/input, rendering, and history contracts.

## Current contract

The viewer must still await installed active-page/overlay/transform readiness for
presentation commands. Core mutations now publish independently. Mode sessions,
drafts, selection, active page, motion, and render caches belong to presentation.

## Implementation

1. Add a viewer document adapter/read projection with selected page ID and the
   PDFKit document/page mapping. Load committed working snapshots under resource
   leases; no PDFKit object or selected page returns to the core model.
2. Subscribe to committed document changes. On source/order changes, install the
   published snapshot; on content changes, refresh affected presentation from
   core content; on rotation, relayout the matching stable page. Detach observers
   and release PDFKit/file leases on retirement. Core publication never calls the
   view to complete required document work.
3. Core commit releases its FIFO slot before presentation waiting. Viewer command
   adapters may await installation/readiness afterward. Keep viewer-only sequencing
   in the interaction owner; do not wrap readiness inside core.submit or create
   another document FIFO. A display failure reports viewer error without rolling
   back valid core/headless data or deleting its working file.
4. Resolve implicit viewer commands to an explicit page ID/index at execution.
   Apply activePage current/firstAdded/lastAdded in the adapter. Preserve selection
   by ID through reorder; choose the established neighboring page on deletion and
   first page on initial creation. No core mutation depends on current viewport.
5. Draft creation/selection/measurement/caret following remain native presentation.
   Apply draft precedence locally, then submit committed text through Task 10's
   core operation. Completed PencilKit drawing uses the same core history path.
   Reconcile core changes affecting the active editor/stroke; reject stale before
   content rather than overwriting newer committed edits. Inactive-page edits
   update state without rebuilding the active overlay.
6. Keep focus/picker/animations/mode tokens in viewer adapters. Document changes
   cancel or retarget presentation under existing captured page/geometry rules;
   cancellation cannot undo an already committed data operation. Viewer close and
   disposal retire presentation requests and use the core lifecycle methods.
7. Build viewer events from current core state plus local mode/error/pageIndex.
   onPageChange carries only pageId/dimensions/rotation/canUndo/canRedo; no dirty,
   content flags, index/count, or revision is added. Deduplicate reported payloads
   after consistent state installation, including callback reentry. getState
   remains the document snapshot; page handles supply full page inspection.
8. Remove migrated view command/model duplication and direct history mutation.
   Preserve stable React callback forwarding; no ref/session counters or readiness
   polling are needed in React for the architectural separation.

## Static validation and completion

- Trace the same edit from headless and viewer clients: one core mutation, then
  optional presentation. Core success does not depend on PDFKit or an observer.
- Inspect observer teardown, file-lease release, event deduplication, mode
  supersession, page deletion, and already-committed publication after cancellation.
- Run `git diff --check`. Proposed commit:
  `refactor(ios): present document-core changes through viewer adapters`.

## Current integration

ViewerDocumentState owns PDFKit objects, selection, and working-file leases. Open/import/remove/move/rotate commit through the core before presentation readiness. Content notifications refresh active overlays; document/structural adapters install the committed snapshot. Current-source compilation and lifecycle checks passed (45/45).
