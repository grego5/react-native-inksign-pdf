# 09 - Extract the headless document core

[Plan](../TASKS.md)

Status: Complete (implementation and applicable simulator checks)
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

The core owns async document FIFO and published state. Viewer adapters own
presentation ordering and PDFKit readiness. FIFO slots survive caller cancellation
until native work finishes; synchronous reads/edits use published state.

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

- Introduced the core as coordinator/resource owner and added main-owner FIFO
  admission independent of mode/presentation tokens. Viewer disposal shuts down
  its core. Open preparation and finalize execute through that FIFO; the viewer
  queue still orders their presentation-facing commands.
- The core owns source read/image conversion, pending working resources, export
  snapshots, worker execution, publication, and cleanup. Workers retain the
  coordinator rather than a view. Core export skips PDFKit interoperability checks;
  backend fixture tests retain them.
- Structural assembly/publication now runs in core admission. Commit releases
  its slot before viewer readiness; presentation failures do not roll back data.
  Reusable viewer close drains FIFO; immediate close rejects queued clients and
  retains running worker lifetime. Discarded structural inputs are released.
- Candidates and committed page/document records now contain PDFium metadata,
  canonical analysis, stable identities, content, and histories. PDFKit objects
  and active selection are removed from these records; viewer adapters own both.
- Headless open publishes independently of presentation; terminal/idempotent
  close rejects new access, drains admitted operations, and awaits worker cleanup.
  Successful export ownership is construction-selected. History policy is stored
  for Task 10's content model. Commit notifications snapshot observer callbacks.
- Viewer selection, working-file leases, and explicit-page structural commands
  are integrated. Runtime lifetime/reentry acceptance awaits the current-source
  validation chat; earlier backend passes do not cover extraction.

- Trace open/add/reorder/rotate/finalize/close without allocating any view.
- Core state has no active selection, PDFKit objects, drafts, viewport, or mode.
- Backend resources are subordinate to the core, not a second content owner.
- Intermediate viewer/handle callers may break until Tasks 11-12; adapt ownership
  directly rather than introducing view-forwarding compatibility shims.
- Run `git diff --check`. Proposed commit:
  `refactor(ios): extract headless document core and resource lifetime`.
