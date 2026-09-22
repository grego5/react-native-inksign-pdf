# Task 04: Add iOS input staging for picker and scanner

[Back to task index](../TASKS.md)

Status: Planned

## Objective

Present native iOS selection UI for `addPages`, launch the existing iOS document
scanner for `scanPages`, and stage ordered PDF/image inputs before processing.

## Non-goals

- Do not mutate PDFs or encode images in this task; both routes return the same
  staged-input model to the coordinator.
- Do not request full photo-library access.
- Do not add generic camera capture, directory selection, or JavaScript picker
  code.

## Read before editing

- `ios/InkSignView.swift`: main-thread lifecycle, promises, and disposal.
- `ios/CacheArtifacts.swift`: cache allocation and exact deletion.
- `ios/InkSignView+Document.swift`: generation replacement and cancellation.
- Existing scanner module source and its iOS result contract: import the
  platform scanner surface directly; no external scanner package is required.

## Current behavior and invariants

iOS opens caller-provided local paths and presents no picker. External
security-scoped URLs and item-provider files cannot outlive their access scope,
while PDF processing needs stable local files.

## Implementation

1. Add one main-thread input coordinator owned by `InkSignView`. It retains one
   pending picker or scanner request, presents only while attached from the
   nearest controller, and invalidates callbacks on open, replacement, and
   disposal.
2. Configure `UIDocumentPickerViewController` for multiple Files selection with
   `UTType.pdf`, `UTType.image`, or both based on optional `type`.
3. Provide Photo Library through multi-select `PHPickerViewController` without
   broad permission. When `type` is omitted or `image`, present a native source
   choice between Files and Photo Library; when `pdf`, open Files directly.
4. Add the `VisionKit` framework and implement `scanPages()` with
   `VNDocumentCameraViewController` and its delegate. Copy each
   `VNDocumentCameraScan.imageOfPage(at:)` result to a unique staged image in
   page order before dismissing the controller.
5. Preserve selection order and resolve each item as `pdf` or `image`.
   Cancellation/dismissal returns an empty selection.
6. For Files, enter security scope, coordinate the read, copy to unique cache,
   and leave scope immediately. For Photos, copy each provider's temporary file
   before its completion scope ends.
7. Copy/validate off the main thread. Return only ordered staged local URLs and
   resolved types; retain no scope URL, provider, or controller in worker state.
8. Delete staged files after partial failure, supersession, replacement, or
   disposal. Use stable errors for missing presenter, unsupported content,
   unreadable cloud items, and stale callbacks.

## Rules

- UIKit/PhotosUI presentation and callbacks are main-actor owned.
- The host application must provide `NSCameraUsageDescription`; the module
  does not request camera access through a separate permission library.
- Balance security-scoped access on every branch.
- External files remain caller/provider owned and read-only.

## Tests

- Test allowed types, source routing, scanner ordering, cancellation,
  supersession, and disposal through injected coordinator seams.
- Verify balanced security scope and cleanup without requiring live cloud UI.
- Run simulator/device smoke tests for Files, Photos, and cloud-backed content.

## Validation

- Run `tools\test-ios-lifecycle.ps1` for local static checks.
- Run focused iOS tests and picker UI smoke tests on macOS.
- Report unavailable macOS/device validation accurately.

## Completion criteria

- iOS stages ordered PDF/image files from Files and images from Photo Library
  without leaking access scopes or temporary resources.

Proposed commit: `feat(ios): add native page file picker`
