# 03 — iOS native picking and shared staging

[Plan index](../TASKS.md)

Status: Implemented — focused verification pending in Task 05
Complexity: High
Depends on: 01

## Objective / non-goals

Restore Files/Photos selection without a PDF viewer. Route direct and selected
inputs through one native staging/encoding path; retain PDFium as authoritative
document backend. No PDFKit analysis, viewport, or text-layout redesign.

## Read before editing

- `ios/HybridInkSignDocument.swift`: `addPages`, factory `createDocument`.
- `ios/DocumentCore.swift`: `submit`, `close`, `dispose`, owner executor.
- `ios/DocumentCore+Pages.swift`: initialization, import, and input staging.
- `ios/DocumentCore+Pages.swift`: `addPages` staging/admission order.
- `ios/DocumentCore+Structure.swift`, `DocumentCoordinator+PageTransactions.swift`:
  staged input conversion, assembly, publication, release.
- `ios/StagedPageInput.swift`, `CacheArtifactPolicy.swift`, `ImagePageEncoder.swift`.
- `references/swift-ios/view-lifecycle.md`: publication and retirement.
- Historical reference: `git show 4e34b8f5^:ios/PageInputCoordinator.swift`.
  Reuse Files/Photos delegates, source-choice UI, ordered provider copies, scoped
  access, and cleanup. The old host-view presenter and per-view lifetime do not apply.

## Existing behavior / evidence

Current `DocumentCore+Pages` stages explicit file URLs on `pdfQueue`, then ends
the transaction and publishes structural work. Opening sniffs JPEG only and copies
other bytes as PDF. The former picker coordinator/tests have been removed.
Canonical source analysis must still be captured through the PDFium candidate loader.

Swift LSP was started for the Mac checkout. Document symbols confirm the factory/
adapter entries; workspace symbol lookup returned no entries and call hierarchy
did not complete. Confirm current local source and Mac hashes before relying on
semantic references; no runtime correctness is inferred from indexing.

## Implementation

1. Restore a native input coordinator using current staged-input/artifact types.
   Resolve the foreground application's presenting controller on main, independent
   of `InkSignView`/PDFKit. A picker call without a suitable foreground presenter
   rejects `missing_presenter`; explicit imports do not need one.
2. Restore Files selection for PDF-only requests. Image/mixed requests offer Files
   or Photos, as before. Files filters use PDF/image UTTypes; Photos filters images
   and preserves selection order. Both allow multiple selection. Anchor popovers
   to the resolved presenter on iPad; no host-view property is needed.
3. Enforce one active platform picker lease; competing presentation rejects
   `operation_in_progress`. Bind delegates/provider completions to the originating
   request. Dismiss/release once, ignoring late results without affecting a later
   request. Presenter/scene destruction cancels; ordinary backgrounding while
   provider UI is active is not by itself proof of cancellation.
4. Move the explicit-source staging block out of `DocumentCore+Pages` into the
   same input coordinator used by selection. Copy security-scoped URLs while
   access is held and NSItemProvider temporary URLs before completion returns.
   IO/decoding stays off main. Validate actual PDF/image bytes against `type`.
   Maintain selected order across out-of-order provider completions.
5. Feed owned staged inputs into existing encoder/backend input conversion.
   All images supported by the existing image encoder use that path, including
   non-JPEG picker images; remove opening's JPEG-only branching. Create from all
   selected inputs through PDFium CREATE, preserving a single-PDF copy path.
   Capture source analysis before publication as the current candidate loader does.
6. Append by selecting/staging within the core FIFO, before ending the text
   transaction or announcing structural work. Complete only after atomic publication.
   User cancellation returns zero/current count; cancelled open rejects
   `operation_cancelled` and releases its unexposed core. Type/staging/assembly
   failure preserves published content and removes all unpublished artifacts.
7. Integrate selection cancellation with `close`/`dispose` before queued cleanup.
   Close cancels active waiting selection and prevents queued picker commands
   from presenting. Their slots reject `operation_cancelled`; already-selected
   imports/direct-source commands drain normally. Detach/mode/navigation do not
   cancel document input work. Provider copies remain owned until their callbacks
   complete, even after the caller has been rejected.
8. Reuse coordinator/PDF queue cleanup for staged inputs after backend consumption;
   do not pass staged paths back through the public API for a second copy.
   Keep current operation identity and exactly-once promise wrappers.

## Ownership / threading

UIKit/PhotosUI belong to native input coordination. The core owns request lifetime
and FIFO admission, not a controller or viewer. Backend mutation consumes only
owned staged inputs. UI runs on main; provider IO is asynchronous; PDFium remains
on `pdfQueue`. Reader leases/export artifacts retain their current owners.

## Regression work / validation

Task 05 supplies focused regressions and authorized Mac verification. Here perform
static source/binding checks and `git diff --check`; no tests/builds. Use Swift LSP
for supported relationship queries, with bounded source fallback for incomplete
indexing. Missing SDK/runtime evidence stays explicitly unverified.

## Completion / proposed commit

Complete when Files/Photos and direct sources share staging, need no PDF viewer,
preserve FIFO/lifetime guarantees, and leave no second legacy input pipeline.

Commit: `feat(ios): restore native document input selection`
