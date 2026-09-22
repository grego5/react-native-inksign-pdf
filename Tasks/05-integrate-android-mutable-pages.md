# Task 05: Integrate mutable pages on Android

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Implement `addPages`, `removePage`, and `movePage` on Android by combining the native picker, the shared PDFium page assembler, stable page identity, and transactional document-session replacement.

## Non-goals

- Do not add structural undo or redo.
- Do not add arbitrary insertion, page swapping, or generic camera capture.
- Do not flatten an added PDF into images.
- Do not expose staged or working file paths through the public API.

## Read before implementation

- `android/src/main/java/com/margelo/nitro/inksignpdf/HybridInkSignView.kt`
- `android/src/main/java/com/margelo/nitro/inksignpdf/InkDocumentState.kt`
- Android surface, PDF session, worker, and export implementations located from those entry points
- `.agents/skills/inksign-pdf-docs/references/android/view-lifecycle.md`
- `.agents/skills/inksign-pdf-docs/references/android/export.md`

## Current state

- The loaded source path and page collection are fixed for the lifetime of the document state.
- Page state and annotation history are associated with page indexes.
- Rendering, mutation, and export already cross UI and serialized worker boundaries.

## Implementation

1. Replace the immutable/index-owned document state with one `MutableDocumentCoordinator`. It exclusively owns the working PDF, ordered stable-ID `PageRecord` collection, current page ID, generation, operation state, and render session. The view delegates; it does not maintain a second page model.
2. During `open`, copy the source into a module-owned working PDF before publishing the document. All rendering, structural mutation, and export use this working PDF; remove branches that continue using the caller's source.
3. Route `open`, `addPages`, `removePage`, `movePage`, and `finalize` through one serialized coordinator state machine. Before structural mutation, commit active text editing, reject an active incomplete ink gesture, and capture the immutable command inputs.
4. Normalize each selected image off the UI thread with the ported
   `react-native-images-to-pdf` encoder: apply EXIF orientation, render onto a
   white page using the active page dimensions captured when the operation
   started, use `contain` fit without cropping, cap output at 200 DPI, and use
   JPEG quality 0.72 when encoding is required. Return optimized JPEG data and
   placement metadata to PDFium; do not create an intermediate image PDF.
5. Implement `addPages` by invoking the Android file picker, encoding each
   image to optimized JPEG data, and appending every selected item in selection
   order. A selected multipage PDF contributes all pages in source order.
   PDFium creates image pages directly from the encoded JPEG data. Create stable
   page states for appended pages and activate the first appended page.
7. Implement `removePage` against the current stable page ID. Reject removal when only one page remains with `last_page_required`; otherwise discard only the removed page's state and activate the page now at the removed index, or the previous page when the removed page was last.
8. Implement `movePage(pageIndex)` by moving the current page in both the working PDF and stable page-state collection. Validate `0 <= pageIndex < pageCount`; treat the current index as a successful no-op and keep the moved page active.
9. Produce a candidate artifact without mutating published state. Validate and open its PDFium session, then atomically publish the candidate PDF, session, ordered page records, active page ID, generation, and dirty state as one coordinator transition.
10. A failed command discards its candidate and staged inputs before leaving the coordinator boundary; published state was never partially mutated. Do not implement field-by-field rollback or fallback reconstruction.
11. Track structural dirty state separately from page-local annotation history. Structural operations must not enter existing page undo or redo stacks.
12. Make final export consume the current working PDF and current page order before applying annotations and ink.

## Correctness and lifecycle rules

- Keep all view and document-state mutation on the UI thread; run image decoding, PDF assembly, session opening, and file I/O on the existing serialized worker boundary.
- Keep every PDFium API call behind the process-wide shared
  `PdfiumLibraryState::apiMutex`. Platform workers own session lifetime and
  ordering but must not add coordinator-owned or per-document PDFium locks;
  helpers invoked while the shared guard is held must not acquire it again.
- Generation belongs to the coordinator and is checked once when an asynchronous command returns to its publication boundary.
- Permit only one picker or structural mutation at a time; reject conflicts with `operation_in_progress`.
- `open` and disposal cancel pending work with `operation_cancelled` and remove owned temporary files.
- Never modify the caller's original PDF.

## Tests

- Unit-test coordinator transitions, stable page identity, remove selection, move shifting, same-index no-op, range validation, structural dirty state, and failed-candidate isolation.
- Test image orientation, white background, aspect-fit sizing, and mixed PDF/image append ordering.
- Add connected coverage for picker result parsing, cancellation, stale-generation suppression, and lifecycle cleanup.
- Verify annotations and ink remain attached to their pages after move and neighboring-page removal.
- Verify export contains the final page count and order after every supported structural operation.
- Concurrently submit rendering and assembly from separate workers and verify
  PDFium entry is serialized without corruption. Exercise open/close while
  another worker renders or assembles, and run ThreadSanitizer where supported.

## Validation

- Regenerate Nitro bindings and run TypeScript checks.
- Run Android unit tests and relevant connected tests.
- Build the Android library and example app.
- Run `git diff --check -- ':!nitrogen/generated/**'`.

## Commit title

`feat(android): support mutable pdf pages`

Status: Complete
