# 03 — Extract iOS document and text ownership

[Plan index](../TASKS.md)

Status: Planned
Complexity: High
Dependencies: 01

## Objective and non-goals

Separate native document/text operations from PDFView presentation while retaining viewer behavior. Do not implement headless constructors or font registration in this task.

## Read before editing

- `ios/InkSignView+Document.swift`: enqueueViewerCommand, openNow, closePublishedDocument, publication readiness.
- `ios/DocumentState.swift`: InkSignPdfDocumentCoordinator, operation tokens, target ownership, page state; `DocumentCandidateLoader.swift`.
- `ios/TextCommands.swift`: getPageNow, resolvePreparedText, setPreparedTextValue/options, content mutations; `HybridAnalyzedPage.swift`, `HybridTextHandle.swift`.
- `ios/TextInteraction.swift`, `TextState.swift`, and `TextRendering.swift`: annotation construction, drafts, reflow, history.
- `ios/MutableDocumentTransactions.swift`, `InkSignView+MutablePages.swift`, and `InkSignView+Export.swift`: structural candidates and snapshot/export orchestration.
- Maintainer architecture, Swift lifecycle/viewport-input/export references; Swift and native-module skills, implementation stage.
- InkSignViewLifecycleTests and InkSignViewTextInteractionTests.

## Current behavior to preserve

InkSignView currently owns FIFO commands and readiness. Canonical source analysis is captured before PDFKit serialization and retained by page state. Text commands call the UI overlay for construction/drafts. PDF queue workers publish only for current operations.

## Implementation steps

1. Introduce `ios/InkSignDocumentOwner.swift` and `ios/DocumentTextCommands.swift`. The owner contains coordinator, FIFO command admission, prepared-page access, artifact tracking, document defaults, and nonpresentation document services.
2. Move loading, candidate assembly, source-analysis retention, export snapshot/publication, and text resolution into these services. Keep PDFView installation/readiness, active overlay, selection, mode tokens, viewport, and callbacks in a viewer adapter.
3. Extract annotation construction/reflow from text interaction into the shared service. Programmatic edits use captured page geometry directly. UI drafts use the same layout/content transaction with overlay hooks.
4. Bind page/text handles weakly to the document owner and stable generation/page/target IDs; viewer focus/session operations retain their additional checks. Analysis remains owner/page-state-owned and is released on close.
5. Apply value and supplied options as one validated content/draft transaction. Do not mutate target options before fallible layout/validation completes. Task 09 completes custom-font selection.
6. Add immutable history-recording configuration: viewer keeps one undo entry per committed mutation; headless retains current content without undo/redo snapshots. Retain source fallback and placement bookkeeping.
7. Route current viewer document operations through the owner while preserving UI readiness timing, lifecycle cancellation, queue release, and callback order. Explicit-source staging must not require a presenting controller.

## Ownership, threading, and geometry

Document state remains on the main thread; native PDF work uses the serial PDF queue. No PDFView/UIView is created by the shared owner. Workers retain only native detached input and settle via supported Nitro scheduling. Preserve media-box origins, canonical coordinates, layout rotation, and immutable source analysis.

## Tests and expected results

Preserve lifecycle, mode cancellation, nonactive-page text mutation, source fallback, geometry, and history tests. Add assertions that a value/options transaction is one undo step and failure leaves target/draft/content unchanged. Shared service tests must construct no PDFView.

## Validation and completion

Use `ssh mac-vm` and the documented hash-verified source sync before running `bash ./tools/test-ios-mac-vm.sh`; focus IOS_TEST_ONLY on lifecycle and text classes. Generated signature integration can remain incomplete until task 09; list exact missing integrations rather than adding placeholders. If the Mac is unavailable, record that runtime validation is pending. Complete when viewer operations use the shared owner and its document/text paths do not depend on presentation.

Proposed commit: `refactor(ios): share document and text ownership`
