# 02 — Android native picking and owned input staging

[Plan index](../TASKS.md)

Status: Implemented — focused verification pending in Task 05
Complexity: High
Depends on: 01

## Objective / non-goals

Support direct/picked open and append without a `ViewerCanvas`. Reuse
`PageInputCoordinator`, byte detection, image encoder, artifacts, and PDFium
assembly. Keep viewer modes, rendering, text geometry, and pager behavior unchanged.

## Read before editing

- `android/src/main/java/com/margelo/nitro/inksignpdf/HybridInkSignDocument.kt`:
  factory `createDocument`, core initialization, `command`, `addPages`, `close`.
- Same directory: `DocumentCore.kt` (`submit`, `prepareOpen`, `addPages`, `close`),
  `PageInputCoordinator.kt` (`copyInto`, `stage`, `stageSources`, request cleanup),
  `CacheArtifactPolicy.kt`, `PdfiumPageAssembler.kt`, `ImagePageEncoder.kt`.
- `ReactNativeInkSignPdfPackage.kt` and installed Nitro `applicationContext`:
  resolve the current React activity without retaining a view/activity globally.
- `references/android/view-lifecycle.md`: inputs, publication, retirement.
- Historical reference only: `git show 6d5ef71d^:android/src/main/java/com/margelo/nitro/inksignpdf/PageInputCoordinator.kt`.
  Its ActivityResult registrar, intent MIME filters, and ordered-result extraction
  are reusable; its per-view ownership is obsolete.

## Existing behavior

The core serializes document operations. `PageInputCoordinator` stages explicit
sources on IO and owns cleanup; `prepareOpen` copies directly to its working file
and converts images through the existing encoder/assembler. `addPages` stages
before ending text editing/announcing structural work. Normal close drains work;
its current `inputs.close()` occurs after queued work and is too late to unblock
a newly introduced waiting picker.

## Implementation

1. Extend input coordination with main-thread native picker launch/result handling.
   Resolve a live `ComponentActivity` from the React context; use ActivityResult
   registration with request identity and unconditional unregister/release.
   Use `ACTION_OPEN_DOCUMENT`, `CATEGORY_OPENABLE`, multiple selection, and MIME
   filters for PDF, image, or both. Missing presenter rejects `missing_presenter`.
2. Keep one active platform picker lease, released on selection/cancel/failure.
   It contains only presentation ownership, not document state or another document
   command queue. Competing presentation rejects `operation_in_progress`.
   Retain the old registrar seam where useful for deterministic completion injection.
3. Feed picked ordered URIs through existing source detection/staging. Normalize
   duplicate URI entries using the former ordered extraction policy. Copy provider
   content before releasing temporary access; classify actual bytes and validate
   `type`. Empty user selection returns an empty staged collection. Partial-copy
   failure removes every request-owned artifact and rejects atomically.
4. Update optional factory/owner inputs. A supplied URI bypasses all UI. Omitted
   URI selects multiple inputs and creates one initial working document in selected
   order using `PdfiumPageAssembler` CREATE and the existing image encoder.
   Preserve the single-PDF copy path where possible. Publish only the complete
   opened document; cancelled/failed opening releases its private core/resources.
5. Change `addPages` to select/stage inside its existing FIFO command. Keep picker
   waiting before `endTextEdit` and `StructuralWriteStarted`; stage and validate all
   sources before mutation. Reuse APPEND and candidate publication. User cancel
   returns zero with current page count and leaves draft/history/events untouched.
6. At normal close admission, cancel only requests waiting for user selection and
   reject queued picker commands before they can launch. Wake their FIFO slots with
   `operation_cancelled`; continue draining admitted direct imports and imports
   already past selection. Forced disposal also cancels IO/request callbacks through
   existing ownership rules. Host destruction cancels selection; ordinary activity
   pause while the picker is foreground preserves it. Viewer detach does not cancel.
7. Close/unregister request resources before later callbacks can target a new
   request. Resume/settle once; cleanup is safe on failure, cancellation, and late
   results. Terminal core cleanup remains the owner of working/backend resources.
8. Adapt constructor/signature callers to generated optional fields without
   broad fixture changes. Keep all defaults, tag/history/font behavior intact.

## Ownership / threading

Input coordinator owns selection and staged files; core owns FIFO and publication.
UI registration/results run on main, copying/decoding on IO, PDFium on its serial
worker. Hold no structural write or backend lock while awaiting user input.
No viewer references, new permissions for broad storage access, or JS file copies.

## Regression work / validation

Task 05 owns regression additions and runtime checks. For this task, inspect source
and generated-signature consistency and run `git diff --check`; no tests/builds in
this chat. Missing activity/SDK evidence is a reported gap, not a fallback to a viewer.

## Completion / proposed commit

Complete when both entry points use native inputs without a viewer, normal close
cannot wait indefinitely for selection, and all staged inputs have one cleanup owner.

Commit: `feat(android): restore native document input selection`
