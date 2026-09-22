# Task 01: Establish the mutable-page public contract

[Back to task index](../TASKS.md)

Status: Complete

## Objective

Define the Nitro API and cross-platform behavior for native file selection,
document scanning, and ordered page mutation before platform implementation
begins.

## Non-goals

- Do not implement picker/scanner presentation, PDF mutation, or image
  conversion in this contract task.
- Do not add generic camera capture, directory browsing, thumbnails, or
  structural undo/redo; `scanPages()` is the platform document-scanner action.
- Do not expose native paths, PDF bytes, security-scoped URLs, or Android
  content URIs to JavaScript.

## Read before editing

- `src/InkSignView.nitro.ts`: `PageInfo`, `StateChangeEvent`, and
  `InkSignViewMethods`.
- `src/index.ts`: exported public types and `InkSignViewHandle`.
- `nitro.json`: `InkSignView` code-generation ownership.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`: Scope, public
  contract, ownership, and cross-platform invariants.

## Current behavior and invariants

The view opens one caller-owned PDF with fixed page count and order. Page-local
history is addressed by index, and `finalize()` assumes the source structure
never changes. Native owns PDF data and worker operations; JavaScript receives
imperative results and coarse metadata only.

## Implementation

1. Add `PageType = 'pdf' | 'image'` and `AddPagesOptions` with optional
   `type?: PageType` to `src/InkSignView.nitro.ts`. Omitted `type` permits both
   supported types.
2. Add `AddPagesResult` with `pageInfo: PageInfo` and
   `addedPageCount: number`. Picker cancellation is a successful no-op with
   `addedPageCount === 0` and unchanged current `PageInfo`.
3. Add these asynchronous methods to `InkSignViewMethods`:
   `addPages(options?: AddPagesOptions): Promise<AddPagesResult>`,
   `scanPages(): Promise<AddPagesResult>`,
   `removePage(): Promise<PageInfo>`, and
   `movePage(pageIndex: number): Promise<PageInfo>`.
4. Define `addPages` as append-only. Permit multiple selected files, process
   them in picker order, append every PDF page in source order, and append one
   page for every image.
5. Define `removePage` as removing the current page. Reject with
   `last_page_required` when only one page remains. Activate the page now at the
   removed index, or the preceding page when the removed page was last.
6. Define `movePage(pageIndex)` as moving the current page to a valid index in
   `0..<pageCount`. Other pages shift, the moved page stays active, and a move
   to its current index is a successful no-op.
7. Require a ready document. Invalid indexes reject before mutation. Permit
   only one picker, scanner, or structural mutation; conflicting calls reject with
   `operation_in_progress`, while `open` and disposal reject pending work with
   `operation_cancelled`.
8. Define `scanPages()` as returning the same result shape and active-page
   behavior as `addPages`, with ordered scanner images converted to pages.
9. Structural mutations set document dirty state outside page-local undo/redo.
   Emit `onPageChange` after the active page and its new metadata are installed;
   emit `onStateChange` for dirty-state changes. Cancellation emits neither.
10. Export the new types from `src/index.ts`, run `npm run nitrogen`, and inspect
   generated signatures without editing generated files manually.
11. Treat the generated contract as authoritative. Do not add compatibility
    aliases, deprecated method names, or placeholder native methods; breaking
    changes are acceptable and native implementations must converge directly
    on the generated API in Tasks 5 and 6.

## Rules

- Use exactly `pdf`, `image`, `addPages`, `scanPages`, `removePage`, and
  `movePage`.
- Do not add insertion-index or swap APIs.
- `PageInfo.pageIndex` stays positional; stable page identity is native-only.
- Picker cancellation does not dirty the document.

## Tests

- Add TypeScript compile fixtures for optional `type`, valid literal values,
  method returns, `scanPages`, and the required move destination.
- Assert unsupported type strings and obsolete method names fail type checking.
- Inspect generated Kotlin and Swift signatures for parity.

## Validation

- Run `npm run nitrogen`.
- Run `npx tsc --noEmit --pretty false`.
- Run `npm run build` after the corresponding native implementation task. Do
  not make an intermediate build pass with placeholder methods.

## Completion criteria

- The public contract has exactly the requested methods and terminology.
- Generated targets agree on append order, cancellation, removal, movement,
  callbacks, and errors.

Proposed commit: `feat(api): define native mutable page operations`
