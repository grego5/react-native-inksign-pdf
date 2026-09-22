# Task 03: Add Android file picker and source staging

[Back to task index](../TASKS.md)

Status: Planned

## Objective

Present native Android selection UI for `addPages` and stage both picker
selections and caller-provided local sources in module-owned cache before
processing.

## Non-goals

- Do not mutate PDFs or encode images in this task; both routes return the same
  staged-input model to the coordinator.
- Do not request broad storage/media permissions.
- Do not add generic camera capture, folder selection, or a JavaScript picker
  module.

## Read before editing

- `android/src/main/java/com/margelo/nitro/inksignpdf/HybridInkSignView.kt`:
  context, promise tracking, attachment, and disposal.
- `android/src/main/java/com/margelo/nitro/inksignpdf/CacheArtifactPolicy.kt`:
  cache allocation and exact cleanup.
- `android/src/main/java/com/margelo/nitro/inksignpdf/ReactNativeInkSignPdfPackage.kt`:
  React context ownership.
- Generated `HybridInkSignViewManager` only to inspect the supplied
  `ThemedReactContext`; do not edit it.
- The caller-provided source contract in `src/InkSignView.nitro.ts`.

## Current behavior and invariants

Android receives local paths from JavaScript and has no activity-result or
content-URI staging path. Cleanup is limited to exact module-created files, and
view disposal cancels pending promises.

## Implementation

1. Add one Android input coordinator owned by `HybridInkSignView` and
   registered with its `ThemedReactContext` activity-result lifecycle. It owns
   exactly one pending picker request and unregisters on disposal.
2. Launch `ACTION_OPEN_DOCUMENT` with `CATEGORY_OPENABLE`, multiple selection,
   and MIME filters from optional `type`: `application/pdf`, `image/*`, or both
   through `EXTRA_MIME_TYPES` when omitted.
3. Preserve provider result order across `data` and `ClipData`, remove exact
   duplicate URIs, and accept mixed selection when unrestricted.
4. When `sources` is supplied, bypass activity-result presentation and stage
   each ordered local path or file URL through the same source-copy path. Do
   not expose staged paths back to JavaScript.
5. Treat cancellation as an empty success. Reject missing activity, detached
   view, malformed result, unsupported content, unreadable stream, or stale
   request with stable errors.
6. Open each picker URI or supported caller-provided URI through
   `ContentResolver`, validate/sniff `pdf` or `image`, and
   copy it to a unique staging file. Never derive a filesystem path from a
   `content://` URI.
7. Return an immutable ordered list of staged native paths and resolved types.
   Delete all staged files on partial failure, supersession, open, or disposal.
8. Keep presentation/results on the main thread and copying on I/O. No activity,
   URI, cursor, or resolver enters worker snapshots.

## Rules

- Add no storage permission.
- Picker/staging owns selection only; document state owns mutation.
- Concurrent `addPages` rejects with `operation_in_progress`.

## Tests

- Unit-test MIME filters, ordered URI extraction, deduplication, source ordering,
  cancellation, and request transitions.
- Use fake providers for one PDF, multiple images, and mixed selection.
- Verify staged-file readability and cleanup after failure/disposal.
- Verify stale results never invoke document mutation.

## Validation

- Run focused JVM tests via `tools\test-android.ps1 -Mode jvm -Test ...`.
- Run focused connected tests when a device is available.
- Defer integrated build success to Task 5 and disclose interim failures.

## Completion criteria

- Android returns an ordered staged PDF/image selection from one multi-select
  system picker without leaking URI or activity ownership.

Proposed commit: `feat(android): add native page file picker`
