# 02 — Extract Android document and text ownership

[Plan index](../TASKS.md)

Status: Planned
Complexity: High
Dependencies: 01

## Objective and non-goals

Make document loading, structural mutation, analysis, text content, and export callable without a view. Keep the viewer's presentation and interaction contract. Do not implement headless constructors or custom-font loading here.

## Read before editing

- `android/src/main/java/com/margelo/nitro/inksignpdf/HybridInkSignView.kt`: open, addPages, preparePage, resolvePreparedText, setPreparedTextValue/options, captureExport/publishExport, launchPromise.
- In that directory: `DocumentCoordinator.kt` MutableDocumentCoordinator; `PdfSession.kt` PdfSessionWorker; `HybridAnalyzedPage.kt` PreparedPageContext/withOwner; `HybridTextHandle.kt`.
- `TextInteractionOverlay.kt`: addTextAnnotation, draft access, direction/defaults; `InkHistory.kt`: TextAnnotation and InkHistory mutations.
- `InkDocumentController.kt`, `PageInputCoordinator.kt`, and `PdfiumPageAssembler.kt` for model/presentation and source staging boundaries.
- Maintainer architecture and Android lifecycle/viewport-input/export references; Kotlin and native-module skills, implementation stage.
- Existing MutableDocumentCoordinatorTest, PreparedTextResolverTest, and HybridInkSignViewTextKeyTest.

## Current behavior to preserve

The coordinator owns stable pages, targets, history, and generation; the view currently also owns the operation queue and text commands. Programmatic insertion calls the text overlay even when a page is captured. Worker PDF access is serialized. Draft → module text → embedded text precedence and complete-label matching must remain unchanged.

## Implementation steps

1. Introduce `InkSignDocumentOwner.kt` and `DocumentTextCommands.kt`. The owner contains coordinator/session worker, queue, admitted-operation identity, artifact tracking, prepared analysis, and text defaults. Move document-only work out of HybridInkSignView into this owner; isolate presentation readiness/publication behind a viewer adapter.
2. Extract text annotation construction/reflow from TextInteractionOverlay.addTextAnnotation so the shared text service accepts explicit page identity, dimensions, target, options, and text. The overlay calls this service for UI insertion instead of being required by programmatic insertion.
3. Bind HybridAnalyzedPage and HybridTextHandle to weak document-owner references plus stable identity/generation. Keep mode-token checks and focus in the viewer adapter. Store retained analysis on the owner so teardown can release it while JS handles remain referenced.
4. Preserve synchronous main-thread dispatch for text commands. Resolve and validate proposed text/options before updating target metadata, draft, or committed content. Apply supplied non-font options in one transaction; task 08 supplies actual custom-font resolution.
5. Add an immutable owner configuration for history recording. Viewer records existing undoable mutations; headless owners update committed content without retaining undo snapshots. Preserve placement/source fallback updates for both paths.
6. Route view loading, page changes, and export through the owner. Keep surface callbacks, tile/raster caches, overlays, viewport waits, mode sessions, and selection in the view. Keep replacement/unmount cancellation behavior and exactly-once settlement.
7. Keep picker presentation in the view integration; extract/reuse explicit-source staging without requiring Activity, surface, or dimensions from a view.

## Ownership, threading, and geometry

The owner is main-thread-owned; PDFium work remains serialized by PdfSessionWorker and source IO stays off the main thread. Worker inputs are detached native values. Preserve canonical/display/layout transforms and captured rotation. No service may manufacture a surface or wait for viewport geometry when called without presentation.

## Tests and expected results

Update coordinator/resolver tests for preserved identities, source fallback, and failed candidate publication. Extend viewer text tests: nonactive-page edits still commit to that page; draft precedence remains; options+value create one undo action; failed edits leave draft/content/target options unchanged. Existing replacement, focus, selection, and history tests retain behavior.

## Validation and completion

Run `tools\test-android.ps1 -Mode jvm -Test com.margelo.nitro.inksignpdf.MutableDocumentCoordinatorTest` and focused PreparedTextResolverTest; after platform integration run build and HybridInkSignViewTextKeyTest with the repository runner. If new generated methods are incomplete, record exact expected failures until task 08; do not claim regression coverage without a runnable test. Complete when document/text services have no view ownership requirement and the viewer uses them.

Proposed commit: `refactor(android): share document and text ownership`
