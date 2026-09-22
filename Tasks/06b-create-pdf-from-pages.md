# Task 06b: Create a PDF from staged pages

Back to task index: [TASKS.md](../TASKS.md)

## Depends on

- [Task 02](02-add-pdfium-page-assembly.md) and [Task 06a](06a-create-or-append-contract.md)

## Objective

Extend the shared PDFium assembler with a creation command that builds a valid PDF from ordered staged inputs without an existing working PDF.

## Implementation

1. Add an explicit `CREATE` command to `core/pdfium-adapter/PdfiumPageAssembler.*` and its Android JNI and iOS Objective-C++ boundaries. `CREATE` accepts no current document and requires at least one input; append, remove, and move still require the current working PDF.
2. Import every selected PDF page as PDF content in source order. Create each image page directly from normalized JPEG bytes and the resolved `imagePageSize`; preserve mixed selection order. Write only a detached candidate artifact, then validate its page count, order, geometry, and reopenability before either platform can publish it.
3. Keep all PDFium calls behind `PdfiumLibraryState::apiMutex`. An invalid input or failed candidate leaves no partial published document or retained scratch artifact.

## Completion

- Native tests cover image-only, PDF-only, and mixed creation, multipage PDF order, image geometry, empty input rejection, and candidate cleanup. Run the focused native assembly suite and `git diff --check -- ':!nitrogen/generated/**'`.

Status: Planned
