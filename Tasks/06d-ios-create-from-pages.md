# Task 06d: Create documents through addPages on iOS

Back to task index: [TASKS.md](../TASKS.md)

## Depends on

- [Task 06a](06a-create-or-append-contract.md)
- [Task 06](06-integrate-ios-mutable-pages.md)

## Objective

Make iOS `addPages` create the first document from selected PDFs and images
through the native Apple PDF backend.

## Implementation

1. Admit page-input staging without a published document. Resolve image page
   dimensions from `imagePageSize` or portrait A4. Preserve picker and
   caller-supplied source ordering.
2. Build a detached `PDFDocument`. Insert every page from selected PDF
   documents directly and create image-backed `PDFPage` instances at the
   resolved point dimensions. Do not route creation through PDFium or page data
   representations.
3. Write and reopen the candidate with PDFKit before publication. Validate
   count, order, geometry, rotation, and visible source content. Do not inspect
   or reject creation because source forms, links, destinations, outlines,
   tags, layers, scripts, embedded files, or digital signatures were not
   retained; those semantics are outside the basic page-merging contract.
4. Cancellation or empty `sources` returns the Task 06a result without changing
   the empty view. Failed creation deletes only owned candidates and staged
   artifacts.

## Completion

- Focused XCTest covers image-only A4/custom size, PDF-only and mixed creation,
  multipage ordering, cancellation without a document, failed candidate
  cleanup, page history, and final export.
- The creation path and its tests require no iOS PDFium session.

Status: Implementation updated; native macOS validation is pending.
