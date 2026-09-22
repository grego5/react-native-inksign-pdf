# Task 07: Document and validate the page workflow

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Document the completed native page workflow, expose it in the example application, and run integrated validation across the TypeScript, Android, iOS, picker, assembly, editing, and export paths.

## Non-goals

- Do not add generic camera capture, page-thumbnail, arbitrary insertion, page
  swapping, or structural undo features.
- Do not replace `addPages` with an application-level external picker.
- Do not broaden the public API beyond the approved contract.

## Read before implementation

- `README.md`
- `example/src/App.tsx`
- `src/InkSignView.nitro.ts`
- `.agents/skills/inksign-pdf-docs/references/architecture.md`
- Updated Android and iOS lifecycle and export references
- Tests introduced by Tasks 01 through 06

## Current state

- Documentation describes a fixed-page editing and signing workflow.
- The example uses an Expo picker to select the initial PDF passed to `open`.
- Maintainer references do not yet describe structural mutations, working PDFs, or native picker ownership.

## Implementation

1. Update the architecture and platform reference documents after implementation so they describe stable page IDs, the module-owned working PDF, transactional session replacement, picker ownership, structural dirty state, and export from current page order.
2. Document the exact public methods and semantics in the README: `addPages(options?)`, `removePage()`, and `movePage(pageIndex)`.
3. State clearly that `addPages()` accepts both PDF and image by default, `type` only restricts the picker, selection may contain multiple items, every selected PDF contributes all pages, and pages are appended.
4. Document cancellation as a successful result with `addedPageCount: 0`, sole-page removal failure, zero-based move destinations, same-index no-op behavior, and operation concurrency errors.
5. Add example controls for unrestricted add, PDF-only add, image-only add, removing the current page, and moving the current page to a requested index.
6. Keep the existing external picker only for initial `open`; use the module's native picker for interactive page acquisition and `addPages({ sources })` for scanner-produced files.
7. Drive example page count, current page, disabled states, and error display from resolved results and existing callbacks rather than assuming mutations succeeded.
8. Run the complete validation matrix and inspect generated artifacts for accidental API or platform drift.

## Tests

- Add or update TypeScript contract tests for all public signatures and result shapes.
- Verify the example handles cancellation without an error and refreshes page state after add, remove, and move.
- Perform a manual parity pass on Android and iOS with mixed image/PDF selection, multipage PDF input, annotations before and after move, removal, and final export.
- Confirm no scanner dependency, camera permission, or unrelated native
  processing dependency was introduced.

## Validation

- Run Nitrogen generation and verify generated diffs are limited to the intended API.
- Run TypeScript linting and type checking.
- Run all relevant native unit and integration tests.
- Build the Android and iOS example applications.
- Validate final exports with mixed inputs on both platforms.
- Run `git diff --check -- ':!nitrogen/generated/**'` and review the complete diff.

## Commit title

`docs: describe native pdf page workflow`

Status: Planned
