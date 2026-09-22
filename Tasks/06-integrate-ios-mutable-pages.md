# Task 06: Integrate mutable pages on iOS

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Implement `addPages`, `removePage`, and `movePage` on iOS using the native picker, shared PDFium page assembly, stable page identity, and transactional replacement of PDFKit and PDFium document state.

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

- The source PDFKit document, PDFium session, and page collection are fixed after open.
- Page state and annotation history use the original numeric page index as identity.
- Rendering and export rely on coordinated PDFKit, PDFium, and view state.

## Implementation

1. Replace the immutable/index-owned document state with one `MutableDocumentCoordinator`. It exclusively owns the working PDF URL, ordered stable-ID `PageRecord` collection, current page ID, generation, operation state, PDFKit document, and PDFium session. The view delegates and holds no parallel page model.
2. During `open`, copy the caller's source into a module-owned working PDF before publishing it. All rendering, mutation, and export use that working PDF; remove branches that retain the source as the live document.
3. Route `open`, `addPages`, `scanPages`, `removePage`, `movePage`, and `finalize` through one serialized coordinator state machine. Before structural mutation, commit active text editing, reject an active incomplete ink gesture, and capture immutable command inputs.
4. Normalize each selected image off the main thread with the ported
   `react-native-images-to-pdf` encoder: apply EXIF orientation, use a white
   background, size the page from the active page dimensions captured when the
   operation started, use `contain` fit without cropping, cap output at 200
   DPI, and use JPEG quality 0.72 when encoding is required. Return optimized
   JPEG data and placement metadata to PDFium; do not create an intermediate
   image PDF.
5. Implement `addPages` by invoking the iOS picker, encoding each image to
   optimized JPEG data, and appending selected items in order. A selected
   multipage PDF contributes every page in source order. PDFium creates image
   pages directly from the encoded JPEG data. Assign stable page states and
   activate the first appended page.
6. Implement `scanPages` by invoking the iOS document scanner, staging its
   ordered image results, encoding them through the same encoder, and appending
   them through the same PDFium image-page command as `addPages`.
7. Implement `removePage` for the current stable page ID. Reject removal of the sole page with `last_page_required`; otherwise remove only that page's state and select the page now at its index, or the preceding page when it was last.
8. Implement `movePage(pageIndex)` by moving the current page in the working PDF and stable collection. Validate the destination range, make a same-index call a successful no-op, and retain the moved page as active.
9. Produce a candidate artifact without mutating published state. Validate and open replacement PDFKit and PDFium documents, then atomically publish the candidate URL, sessions, ordered page records, active page ID, generation, and dirty state as one coordinator transition.
10. A failed command discards its candidate, releases security scopes, and deletes staged files before leaving the coordinator boundary; published state was never partially mutated. Do not implement field-by-field rollback or fallback reconstruction.
11. Keep structural dirty state independent of page-local undo and redo history.
12. Update final export to use the current working PDF and page order before applying ink and annotations.

## Correctness and lifecycle rules

- Restrict UIKit, PDFKit view state, and document-state installation to the main actor. Keep image decoding, PDF assembly, and file coordination off the main actor.
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

## Validation

- Regenerate Nitro bindings and run TypeScript checks.
- Run iOS unit tests and the example build.
- Exercise Files and Photo Library flows on a simulator or device where available.
- Run `git diff --check -- ':!nitrogen/generated/**'`.

## Commit title

`feat(ios): support mutable pdf pages`

Status: Planned
