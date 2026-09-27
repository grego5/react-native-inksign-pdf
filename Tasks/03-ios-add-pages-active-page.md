# Choose the active page after `addPages()` on iOS

[Task index](../TASKS.md)

Status: Planned
Complexity: Medium

## Objective and non-goals

Implement the shared `AddPagesOptions.activePage` choice on iOS after Task 01 adds the Nitro field and regenerates bindings. Omission and `current` retain the active page when appending to a document; `firstAdded` and `lastAdded` select the respective page added by this call. During document creation, `current` selects the first added page. Return `pageInfo` for the resulting active page.

Do not change Android, page order, imported content, page-local history, viewport policy, picker behavior, or unrelated structural commands.

## Read before editing

- `Tasks/01-add-pages-active-page.md` and `src/InkSignView.nitro.ts`: the shared option and generated Swift representation. Verify Task 01 is complete before consuming the option; do not edit `nitrogen/generated/**` by hand.
- `ios/InkSignView+MutablePages.swift`: `addPages`, `assembleStructuralCandidate`, `installStructuralPresentation`; `ios/MutableDocumentTransactions.swift`: `StructuralInput`, `.append`; `ios/DocumentState.swift`: `PageOrder`, `pageOrder`.
- `ios/tests/InkSignViewLifecycleTests.swift`: page-order and mixed-source append coverage; the focused page-input tests for cancellation and empty sources.
- `.agents/skills/inksign-pdf-docs/references/development.md`, `architecture.md`, and `swift-ios/view-lifecycle.md`: publication, page identity, and validation ownership.

## Current behavior and invariants

The iOS append candidate currently selects the first appended page even when a document already has an active page. `addPages` stages inputs, assembles and validates a detached candidate on `pdfQueue`, then publishes and installs it on the main thread. Page IDs and histories follow the ordered records. Empty staging resolves with zero additions and no mutation; failed, cancelled, or stale page mutations retain the published document and active page.

## Implementation

1. In `InkSignView+MutablePages.addPages`, resolve the generated optional choice to `current` and carry it through structural candidate assembly. Use the existing admitted operation; do not select a page on the published coordinator during staging.
2. In `MutableDocumentTransactions.assembleCandidate`, build the appended page records once and choose the candidate active ID before writing and reopening it: existing active ID for `current` with an existing document; first appended ID for creation or `firstAdded`; last appended ID for `lastAdded`. Adjust the append page-order path in `DocumentState.swift` so it accepts that choice without changing remove or move behavior. Keep page count and order independent of selection.
3. Publish the selected active ID with the candidate. Let `installStructuralPresentation` navigate to the candidate's active page, and resolve `AddPagesResult.pageInfo` from the published active page. Preserve the existing viewport policy and callback ordering.
4. After iOS behavior is implemented, revise `README.md`, the architecture overview, and `swift-ios/view-lifecycle.md` to describe both platforms accurately and remove the pending-iOS qualifier introduced by Task 01.

## Tests and verification

Extend focused iOS lifecycle coverage with a deterministic multi-page source. Starting from a non-first active page, assert that omitted/`current` preserves its stable page ID and index, `firstAdded` selects the first page imported by that call, and `lastAdded` selects the last; each returned `pageInfo` must identify the same active page. Add a creation case in which `current` selects the first added page. Keep empty/cancelled import and page-history checks as regression coverage. Assert state after publication, without depending on PDFKit layout timing.

After the no-tests/builds restriction is lifted, run the focused iOS lifecycle selection through `IOS_TEST_ONLY` with `./tools/test-ios-mac-vm.sh` or the repository iOS runner, then the relevant lifecycle suite. Report the exact unrun gate if the Mac VM or simulator is unavailable. Under the current restriction, perform static review and `git diff --check -- ':!nitrogen/generated/**'` only.

Complete when iOS candidate publication, active presentation, and returned `pageInfo` agree for all three choices and creation, failure/cancellation leave the current page intact, and documentation reflects parity. Proposed commit: `feat(ios): select active page after addPages`.
