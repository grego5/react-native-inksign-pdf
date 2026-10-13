# 09 - Extract the headless document core

[Plan](../TASKS.md)

Status: Planned
Complexity: High
Depends on: 08

## Objective and non-goals

Create one Swift document owner usable without a view. Reuse existing lifecycle,
operation, backend, and artifact implementations. Remove presentation objects
and active-page selection from committed state; do not create a parallel document
or replace the existing interaction/viewport owners.

## Read before editing

- Android `DocumentCore.kt`, `DocumentReadState.kt`, `DocumentCoordinator.kt`,
  and `ViewerDocumentState.kt`: boundaries and admission/resource policy.
- `ios/InkSignView.swift`: `ViewerCommand`, `commandQueue`, running commands.
- `ios/InkSignDocumentState.swift`: coordinator, operation tokens, document/page
  state, `activePageID`, PDFDocument/PDFPage, artifact publication.
- `ios/InkSignView+Document.swift`, `MutableDocumentTransactions.swift`,
  `DocumentCandidateLoader.swift`, and `InkSignView+Export.swift`.
- Tasks 01-07's backend, metadata, analysis, and writer; maintainer architecture
  document-operation and iOS lifecycle contracts.

## Current contract

InkSignView owns command ordering; state embeds PDFKit objects and selection.
The backend phase preserves this temporarily. Async FIFO slots survive caller
cancellation until native work finishes; synchronous reads/edits use published
state. Those rules must survive extraction.

## Implementation

1. Introduce `InkSignDocumentCore` by moving document command admission/order,
   lifecycle, working-file/resource ownership, committed state, target/analysis
   caches, structural operations, export, and cleanup out of the view. Existing
   coordinator helpers may remain private implementation details with one state
   store. No core field or operation requires an InkSignView/overlay callback.
2. Keep state publication on one owner executor (main queue, matching existing
   synchronous Nitro entry points); keep PDF reads/writes on the serial PDF queue.
   Async commands share the core FIFO. Sync page edits/reads use published state
   directly; do not block the owner queue waiting for worker work.
3. Replace document/page PDFDocument/PDFPage members with ordered stable IDs,
   source/current geometry, committed content, history, and owned analysis.
   Remove activePageID/activePageIndex and active-page mutations from the core.
   Core commands require explicit indices/IDs; derive page position from order.
4. The core owns the internal backend resource binding. Retained native sessions
   live/access/close on the worker; they own working input bytes and no logical
   history/dirty/target state. Prepare and validate candidates before atomic
   core publication. Bind prepared handles/caches to document generation and
   stable page IDs; replacing source content invalidates affected records.
5. Headless commit/return depends on PDFium validation only. Move PDFKit candidate
   creation/reopening and readiness out to the later viewer adapter. Finalize
   snapshots are core-owned immutable values, not InkSignView members.
6. Configure history/export ownership when creating a core: viewer history on
   with document-owned outputs; headless history off with caller-owned successful
   outputs, matching Android. Presentation attachment never changes those policies.
7. Headless close is terminal/idempotent: immediately stop new admission/reads,
   drain admitted work, invalidate handles, and await backend/font/artifact cleanup.
   Separate client admission from admitted-command validity: normal close does
   not cancel earlier commands merely because the lifecycle is now closing.
   Immediate dispose cancels publication but retains running worker resources.
   Viewer ordinary close clears its document in FIFO without making the reusable
   viewer owner terminal; disposal shuts its core down.
8. Publish small internal document-change notifications after consistent commits.
   Observers never perform required document work or hold FIFO progress. Deliver
   outside admission locks and account for callback reentry. Presentation leases
   retain retired working files only while backend/PDFKit readers still need them;
   release and retire them through core-owned cleanup, not a retained original copy.

## Static validation and completion

- Trace open/add/reorder/rotate/finalize/close without allocating any view.
- Core state has no active selection, PDFKit objects, drafts, viewport, or mode.
- Backend resources are subordinate to the core, not a second content owner.
- Intermediate viewer/handle callers may break until Tasks 11-12; adapt ownership
  directly rather than introducing view-forwarding compatibility shims.
- Run `git diff --check`. Proposed commit:
  `refactor(ios): extract headless document core and resource lifetime`.
