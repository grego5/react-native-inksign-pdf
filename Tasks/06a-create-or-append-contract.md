# Task 06a: Extend the create-or-append contract

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Let `addPages` create the first document as well as append pages, while keeping `open(path)` an unconditional PDF replacement command.

## Implementation

1. In `src/InkSignView.nitro.ts`, add a named `ImagePageSize` type with `width` and `height` in PDF points, and `AddPagesOptions.imagePageSize?: ImagePageSize`. Validate finite positive dimensions at the native command boundary. Use the option for every image in the action; otherwise use the active page size for an existing document or portrait A4 (595.28 × 841.89 points) for creation. PDF inputs retain their own dimensions.
2. Make `AddPagesResult.pageInfo` optional. A canceled picker or empty `sources` returns `addedPageCount: 0` and leaves state unchanged: return the active `pageInfo` when a document exists, and omit it when none exists. A successful import always returns the new active `pageInfo`.
3. Keep PDF/image selection order, multipage PDF expansion, page-local history, and the existing `open(path)` signature. `removePage`, `movePage`, and `finalize` continue to require a document. Successful creation sets the first added page active and marks the document dirty.
4. Regenerate Nitro bindings; update TypeScript callers and contract tests for the optional result field and image size input. Do not edit generated files manually.

## Completion

- The public type and native validation rules agree on points, A4 fallback, cancellation, and success results. Run Nitrogen, TypeScript checks, and `git diff --check -- ':!nitrogen/generated/**'`.

Status: Planned
