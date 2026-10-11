# 04 — Implement Android headless document operations

[Plan index](../TASKS.md)

Status: Planned
Complexity: High
Dependencies: 02

## Objective and non-goals

Implement Android factory, document, and page handles with deterministic close and caller-owned export outputs. Do not create UI, expose undo/state, or implement font loading here.

## Read before editing

- Task 01's spec and task 02's InkSignDocumentOwner/DocumentTextCommands.
- `PdfSession.kt`: PdfSessionWorker.prepareOpen, prepareMutation, preparePageAnalysis, close(outputs, retireOutput), closeCurrent.
- `DocumentCoordinator.kt`: structural candidates, operation admission, executeStructuralMutation, exportSession, cleanup.
- `PageInputCoordinator.kt`: stageSources/openLocalSource/detectType; ImagePageEncoder and PdfiumPageAssembler.
- `CacheArtifactPolicy.kt`: signed output allocation and startup scavenging.
- `HybridInkSignView.kt`: current export publication/output tracking and disposal.
- Maintainer architecture, Android lifecycle/export, diagnostics-validation references; native-module/Kotlin implementation skills.

## Current behavior to preserve

Sources are staged and assembled into detached candidates. Failed mutations preserve published content. Current worker close schedules cleanup and returns before it runs; this is insufficient evidence that awaited headless close has released resources. Viewer outputs remain view-owned.

## Implementation steps

1. Implement `HybridInkSignDocumentFactory.kt`, `HybridInkSignDocument.kt`, and `HybridDocumentPage.kt` from generated specs. Factory uses application Context, creates an independent owner, opens native source content, and returns only after document metadata/analysis is ready. Release the owner on failed open.
2. Route PDF and supported images through explicit source staging/encoding, using A4/default import settings unless options specify otherwise. No Activity, mounted view, nonzero viewport, picker, tile rendering, or surface creation is required.
3. Implement explicit zero-based page operations. Append sources in order, return added/total count, and preserve current content on failure. Remove only the named page, reject removing the sole page, move source index to final destination index, and rotate clockwise by existing 90/180/270 values.
4. Keep readonly pageCount and DocumentPage.info synchronous on the owner thread. Info reflects the handle's current index/geometry after move/rotation. getPage(index) prepares analysis through FIFO execution and returns a weak owner-bound handle.
5. Export committed content through the shared exporter. Transfer the validated published output out of owner deletion tracking before success settles. Repeated finalize exports independent files; failure retires unpublished files.
6. Implement a terminal closing state synchronously when close is invoked. Reject new commands/reads/text edits, let already-admitted async operations finish, then invalidate handles and release the owner.
7. Add completion acknowledgement to worker teardown and await IO/artifact cleanup before close resolves; never block the main thread waiting for its own callbacks. Repeated close returns the same completion. Nitro disposal performs safe asynchronous cleanup when explicit close was omitted.
8. Retain successful outputs through close/disposal; preserve existing cache scavenging and viewer ownership behavior. Delete only owned working/staged/scratch/unpublished files, never caller sources.

## Ownership and lifecycle rules

Each document has its own queue/worker/coordinator. Indexes bind when queued work executes; returned page handles bind stable page IDs. Surviving handles remain valid after append/move/rotation; removed/closed handles reject with existing cancellation errors. In-flight exports retain snapshots until their worker finishes.

## Tests and expected results

Add HybridInkSignDocumentTest instrumentation coverage: open PDF/JPEG/PNG without an Activity/view; read/write Hebrew text and free bounds; append/move/rotate/remove; preserve state after bad import; stale removed handles reject. Compare source hashes before/after. Repeated exports reopen with supported visible annotations/signatures, and remain readable after close. A controlled worker proves close waits for cleanup and rejects newly admitted work.

## Validation and completion

Run `tools\test-android.ps1 -Mode jvm`, `-Mode build`, and `-Mode connected -Test com.margelo.nitro.inksignpdf.HybridInkSignDocumentTest`. Select device ABI explicitly when needed. Until task 08, record missing font integrations. Complete when headless document operations and deterministic teardown pass; offline builds do not count as device validation.

Proposed commit: `feat(android): add headless document operations`
