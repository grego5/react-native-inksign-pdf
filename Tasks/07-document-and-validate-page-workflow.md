# Task 07: Document and validate the page workflow

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Document the completed native page workflow, expose it in the example
application, and validate the shared product contract across the Android
PDFium backend and Apple-framework iOS backend.

## Non-goals

- Do not add generic camera capture, page-thumbnail, arbitrary insertion, page
  swapping, or structural undo features.
- Do not replace `addPages` with an application-level external picker.
- Keep the public API limited to the create-or-append contract in Tasks 06a–06e.

## Read before implementation

- `README.md`
- `example/src/App.tsx`
- `src/InkSignView.nitro.ts`
- `.agents/skills/inksign-pdf-docs/references/architecture.md`
- Updated Android and iOS lifecycle and export references
- Tests introduced by Tasks 01 through 06

## Current state

- The public contract is shared, but PDF engine ownership is platform-specific:
  Android uses PDFium and iOS uses PDFKit, Quartz, and CoreText.
- The example uses an Expo picker to select the initial PDF passed to `open`.
- Android and iOS picker ownership, example controls, and end-to-end validation
  remain to be documented after Tasks 3 through 6.

## Implementation

1. Update the architecture and platform references after implementation so
   they describe stable page IDs, the module-owned working PDF, transactional
   replacement, picker ownership, structural dirty state, and export from the
   current page order. State the Android PDFium and native iOS ownership
   boundaries separately.
2. Document the exact public methods and semantics in the README: `addPages(options?)`, `removePage()`, and `movePage(pageIndex)`.
3. State clearly that `addPages()` accepts both PDF and image by default, creates a document when none exists, and otherwise appends. Document multipage PDF expansion, mixed selection order, A4 image-page default, `imagePageSize` in PDF points, and `type` as a picker restriction.
4. Document cancellation as `addedPageCount: 0` with no `pageInfo` only when no document exists. Include sole-page removal failure, zero-based move destinations, same-index no-op behavior, operation concurrency errors, and failed replacement-open preservation.
5. Add example controls for unrestricted add, PDF-only add, image-only add, image page size, removing the current page, and moving the current page to a requested index.
6. Keep `open(path)` for explicit PDF replacement. Use the module's native picker for interactive creation and page acquisition, and `addPages({ sources })` for scanner-produced files.
7. Drive example page count, current page, disabled states, and error display from resolved results and existing callbacks; handle an empty-view cancellation without assuming `pageInfo` exists.
8. Run the complete validation matrix and inspect generated artifacts for accidental API or platform drift.
9. Publish the Task 6f interoperability results: page import, image pages,
   geometry, locked-but-copyable text annotations, read-only locked vector
   signature annotations, external viewers, performance, file ownership, and
   transactional publication. State that advanced source PDF semantics are
   outside the basic editing contract and their loss is not incomplete work.

## Tests

- Add or update TypeScript contract tests for all public signatures and result shapes.
- Verify the example handles cancellation with and without a document and refreshes page state after creation, add, remove, and move.
- Perform a manual parity pass on Android and iOS with empty-view creation, mixed image/PDF selection, multipage PDF input, annotations before and after move, removal, failed replacement open, and final export.
- Confirm no scanner dependency, camera permission, or unrelated native
  processing dependency was introduced.

## Validation

- Run Nitrogen generation and verify generated diffs are limited to the intended API.
- Run TypeScript linting and type checking.
- Run all relevant native unit and integration tests.
- Build the Android and iOS example applications.
- Validate final exports with mixed inputs on both platforms.
- Inspect the packaged iOS product and confirm it contains no PDFium binary,
  bridge, header, resource, or runtime symbol. Confirm Android still packages
  and verifies its pinned PDFium dependency.
- Run `git diff --check -- ':!nitrogen/generated/**'` and review the complete diff.

## Commit title

`docs: describe native pdf page workflow`

Status: Planned
