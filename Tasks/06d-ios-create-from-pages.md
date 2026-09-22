# Task 06d: Create documents through addPages on iOS

Back to task index: [TASKS.md](../TASKS.md)

## Depends on

- [Task 06](06-integrate-ios-mutable-pages.md) and [Task 06b](06b-create-pdf-from-pages.md)

## Objective

Make iOS `addPages` create the first document from selected PDFs and images through its existing coordinator and candidate loader.

## Implementation

1. Admit page-input staging with no published document. Resolve image dimensions from `imagePageSize`, the active page when present, or A4. Preserve the existing picker and caller-provided source ordering.
2. In `InkSignPdfDocumentCoordinator`, use shared `CREATE` assembly for an empty document and `APPEND` for an existing one. Reopen and validate the candidate with `InkSignPdfDocumentCandidateLoader`, then publish the working file, PDFKit/PDFium sessions, stable page records, first active page, generation, and dirty state together. Keep UIKit presentation installation on the main thread.
3. On cancellation or empty `sources`, return Task 06a's result without changing the empty view or active editor. Failed creation closes the candidate session and removes only owned artifacts. Export after creation uses the new ordered working PDF.

## Completion

- Focused XCTest covers image-only A4/custom size, PDF-only and mixed creation, cancellation without a document, failed candidate cleanup, page history, and final export. Run the iOS simulator suite and example build on macOS, plus `git diff --check -- ':!nitrogen/generated/**'`.

Status: Planned
