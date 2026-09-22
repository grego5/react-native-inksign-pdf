# Task 06: Integrate mutable pages on iOS

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Implement `addPages`, `removePage`, and `movePage` on iOS using the native picker, shared PDFium page assembly, stable page identity, and transactional replacement of PDFKit and PDFium document state.

## Depends on

- [Task 02](02-add-pdfium-page-assembly.md), [Task 04](04-add-ios-file-picker.md), and [Task 05b](05b-centralize-ios-operations.md). Task 05b includes the Task 05a coordinator ownership work.

## Non-goals

- Do not add structural undo or redo.
- Do not add arbitrary insertion, page swapping, or generic camera capture.
- Do not flatten an added PDF into images.
- Do not expose staged or working URLs through the public API.

## Read before implementation

- `ios/InkSignView.swift`
- `ios/DocumentState.swift`
- iOS PDFium session, rendering, and export implementations located from those entry points
- `.agents/skills/inksign-pdf-docs/references/swift-ios/view-lifecycle.md`
- `.agents/skills/inksign-pdf-docs/references/swift-ios/export.md`

## Current state

- The coordinator owns a working PDF, stable-ID page records, current page ID, operation admission, and export snapshots.
- The PDFKit document, PDFium session, and ordered page collection are fixed after open until this task adds structural publication.

## Implementation

1. Extend the coordinator from Tasks 05a and 05b to admit `addPages`, `removePage`, and `movePage` through its existing operation boundary. Before structural mutation, commit active text editing, reject an active incomplete ink gesture, and capture immutable command inputs.
2. Normalize each selected image off the main thread with the ported
   `react-native-images-to-pdf` encoder: apply EXIF orientation, use a white
   background, size the page from the active page dimensions captured when the
   operation started, use `contain` fit without cropping, cap output at 200
   DPI, and use JPEG quality 0.72 when encoding is required. Return optimized
   JPEG data and placement metadata to PDFium; do not create an intermediate
   image PDF.
3. Implement `addPages` by invoking the iOS picker, encoding each image to
   optimized JPEG data, and appending selected items in order. A selected
   multipage PDF contributes every page in source order. PDFium creates image
   pages directly from the encoded JPEG data. Assign stable page states and
   activate the first appended page.
4. Implement `removePage` for the current stable page ID. Reject removal of the sole page with `last_page_required`; otherwise remove only that page's state and select the page now at its index, or the preceding page when it was last.
5. Implement `movePage(pageIndex)` by moving the current page in the working PDF and stable collection. Validate the destination range, make a same-index call a successful no-op, and retain the moved page as active.
6. Produce a candidate artifact without mutating published state. Validate and open replacement PDFKit and PDFium documents, then atomically publish the candidate URL, sessions, ordered page records, active page ID, generation, and dirty state as one coordinator transition.
7. A failed command discards its candidate, releases security scopes, and deletes staged files before leaving the coordinator boundary; published state was never partially mutated. Do not implement field-by-field rollback or fallback reconstruction.
8. Keep structural dirty state independent of page-local undo and redo history.
9. Verify final export snapshots reflect the current working PDF and page order before applying ink and annotations.

## Correctness and lifecycle rules

- Restrict UIKit, PDFKit view state, and document-state installation to the main actor. Keep image decoding, PDF assembly, and file coordination off the main actor.
- Keep every PDFium API call behind the process-wide shared
  `PdfiumLibraryState::apiMutex`. Platform workers own session lifetime and
  ordering but must not add coordinator-owned or per-document PDFium locks;
  helpers invoked while the shared guard is held must not acquire it again.
- Generation belongs to the coordinator and is checked once when asynchronous work returns to its publication boundary.
- Permit only one picker or structural operation at a time; reject conflicts with `operation_in_progress`.
- `open` and disposal cancel pending work with `operation_cancelled` and clean owned artifacts.
- Never overwrite the caller's original PDF or retain security-scoped access beyond staging.

## Tests

- Unit-test coordinator transitions, stable identity, destination shifting, same-index no-op, removal selection, range validation, dirty state, and failed-candidate isolation.
- Test image orientation, color/background behavior, aspect-fit geometry, and mixed PDF/image ordering.
- Exercise picker cancellation, provider-backed files, stale-generation suppression, and resource cleanup.
- Verify ink and annotations stay with the same page after move and removal of another page.
- Verify final export preserves the final count, order, dimensions, and page content.
- Concurrently submit rendering and assembly from separate workers and verify
  PDFium entry is serialized without corruption. Exercise open/close while
  another worker renders or assembles, and run ThreadSanitizer where supported.

## Validation

- Regenerate Nitro bindings and run TypeScript checks.
- Run iOS unit tests and the example build.
- Exercise Files and Photo Library flows on a simulator or device where available.
- Run `git diff --check -- ':!nitrogen/generated/**'`.

## Commit title

`feat(ios): support mutable pdf pages`

Status: Planned
