# 01 — Public picker contract and bindings

[Plan index](../TASKS.md)

Status: Complete
Complexity: Medium
Depends on: None

## Objective / non-goals

Native selection belongs to `document.addPages()`, independently of the viewer.
`createDocument(options?)` synchronously returns the owner; optional initial
sources load before subsequent commands. No separate picker or viewer import method.

## Read before editing

Lookup map; read only the next relevant declaration/caller:

- `src/InkSignDocument.nitro.ts`: creation/import options, factory, document methods.
- `src/InkSignTypes.ts`: shared data-only types.
- `src/index.ts`: `createDocument`, `createValidatedDocument().addPages`.
- `src/publicArguments.ts`: `validateAddPagesOptions`, source validation.
- `nitro.json`; generated factory/document specs (inspection only).
- Maintainer `references/architecture.md`: ownership, commands, import/export.
- `tools/view-ref.test.cjs`: real public-wrapper dispatch harness.

## Input contract

Creation with omitted/empty sources stays empty. `addPages()` with omitted sources
opens native selection; explicit sources bypass it. Preserve encoding, tags,
history configuration, and fallback-font options independently of the viewer.

## Implementation

1. Define shared `PageInputType = 'pdf' | 'image'`. Add optional `type` to
   `DocumentOptions` and `DocumentAddPagesOptions`. A missing type accepts
   either; type limits apply to detected content in both direct and picked paths.
2. Factory/public `createDocument(options?: DocumentOptions)` returns synchronously.
   Initial sources enter the core FIFO; loading failures reach viewer state and
   reject dependent commands. Closing a failed owner remains available.
3. Make `document.addPages(options?: DocumentAddPagesOptions)` and `sources?: string[]`.
   Omitted options/sources invokes selection; an explicit empty array imports zero.
   Remove the wrapper's explicit-sources-only guard. Retain other input validation.
4. Add concise JSDoc: headless calls may present platform UI; types constrain actual
   input; selection is multiple/ordered; user-cancelled append resolves
   `{ addedPageCount: 0, pageCount: currentCount }`. Lifecycle cancellation
   rejects `operation_cancelled`.
5. Preserve caller source ordering, tag assignment to every imported page, and
   image encoding defaults/options. Unsupported or type-mismatched content rejects
   the complete operation before publication (`unsupported_content`).
6. Run `npm run nitrogen`; inspect generated optional parameters/options on both
   native factories/documents and their C++ adapters. Modify authoritative specs,
   never generated files by hand. No separate JS file-staging or URI registry.

## Ownership / lifecycle rules

- Select/stage natively; JavaScript passes optional inputs/options and receives
  existing document/result objects only.
- Preserve FIFO invocation order. Native tasks define cancellation while waiting
  for UI; do not add React counters, picker callbacks, or viewer state.
- The single active platform picker lease rejects competing presentation with
  `operation_in_progress`; multiple commands on one owner follow its existing FIFO.
- Imports succeed at core publication, not viewer readiness.

## Regression work / validation

Task 05 adds public-wrapper behavior checks and runs validation. In this task,
only generate bindings and run `git diff --check`. Native compile mismatches are
expected until Tasks 02/03 update implementations and generated-option callers.
Report generation failures without claiming native compatibility.

## Completion / proposed commit

Complete when declarations, wrapper forwarding, and generated signatures express
this contract, with no accidental viewer API change.

Commit: `feat(api): restore optional native selection for document inputs`

## Completion evidence

- Added shared/public `PageInputType`, optional input/type fields, cancellation and
  atomic-import JSDoc, and wrapper forwarding for omitted inputs. Explicit invalid
  URIs still reject; explicit empty source arrays retain their meaning.
- `npm run nitrogen` succeeded for all six Hybrid Objects. Inspected optional
  Swift/Kotlin factory/document signatures and C++ input/options declarations.
- Authored-file `git diff --check -- ':!nitrogen/generated/**'` passed. Full diff
  checking reports five whitespace warnings emitted by Nitrogen; generated output
  was preserved. No tests/builds ran. Native compatibility awaits Tasks 02/03.
- TypeScript MCP-LSP has no configured project for this repository; focused source
  searches supplied wrapper/caller discovery for this task.
