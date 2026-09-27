# Choose the active page after `addPages()`

[Task index](../TASKS.md)

Status: Planned
Complexity: Medium

## Objective and non-goals

Add `activePage?: 'current' | 'firstAdded' | 'lastAdded'` to `AddPagesOptions`. For an existing document, omission and `current` retain the current active page; `firstAdded` and `lastAdded` select the respective page added by this call. For document creation, `current` selects the first added page because there is no previous active page. A cancelled or empty import changes neither the active page nor page count.

Implement Android behavior and the shared public type. iOS native behavior is a later task. Do not change page order, page histories, import processing, viewport policy, or unrelated structural commands.

## Read before editing

- `src/InkSignView.nitro.ts`: `AddPagesOptions`, `AddPagesResult`; `src/publicArguments.ts`: `validateAddPagesOptions`; `src/index.ts`: `addPages` dispatch.
- `android/src/main/java/com/margelo/nitro/inksignpdf/HybridInkSignView.kt`: `addPages`; `DocumentCoordinator.kt`: `appendCandidate`, `StructuralCandidate`; `SurfaceView.kt`: `installStructuralPresentation`.
- `.agents/skills/inksign-pdf-docs/references/development.md`, `architecture.md`, and `android/view-lifecycle.md` for source ownership and publication rules. Inspect relevant Android create/append tests before adding coverage.

## Current behavior and invariants

`DocumentCoordinator.appendCandidate` makes the first appended page active. The candidate carries stable page identities and page-local histories through one validated structural publication. `addPages()` returns information about the active page after publication. Empty staging returns zero added pages without mutation. Android's current structural presentation and callback policy are outside this task.

## Implementation

1. Add a single optional `activePage` union to the Nitro options. Validate only `current`, `firstAdded`, and `lastAdded` at the JavaScript boundary; omission resolves to `current`. Use the existing async argument-error path. Do not add a boolean alias.
2. Regenerate Nitro bindings with `npm run nitrogen` during implementation; never edit `nitrogen/generated/**` by hand. Because the options type is shared, generated iOS option fields may change, but defer iOS native behavior and iOS-specific tests.
3. Pass the selected value through `HybridInkSignView.addPages` to candidate construction. Build the appended records once, then choose the candidate active ID: existing ID for `current` when a document exists; first appended ID for creation or `firstAdded`; last appended ID for `lastAdded`. Keep selection within the detached candidate so failed, cancelled, or stale work cannot change the published page.
4. Publish through the existing structural transaction. Return `pageInfo` for the resulting active page. Update `README.md` and the owning architecture/Android lifecycle reference to describe Android behavior and state that iOS native parity remains pending.

## Tests and verification

Use the existing Android create/append instrumentation harness and a deterministic multi-page fixture. Add one focused scenario that checks the resulting active page and returned `pageInfo` for default/`current`, `firstAdded`, and `lastAdded`; add a creation scenario showing that `current` selects the first page when no document exists. Keep the established empty/cancelled-import and page-history coverage as regression checks. Assert stable page identity and index, independent of viewport timing or picker UI.

Run `npm run nitrogen` to produce the required bindings. Intended checks after the no-tests/builds restriction is lifted: `npm run test:public-api`, `npx tsc --noEmit --pretty false`, and `tools\test-android.ps1 -Mode connected -Test com.margelo.nitro.inksignpdf.HybridInkSignViewCreatePagesTest` plus the focused append/navigation class. If a device or runner is unavailable, report that and the exact unrun gate. During the current restriction, use static inspection and `git diff --check -- ':!nitrogen/generated/**'` only.

Complete when the Android active-page choice and result match the three public values, docs reflect the implemented platform behavior, and deferred validation is reported truthfully. Proposed commit: `feat(android): select active page after addPages`.
