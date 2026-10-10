# 04 - Consolidate page presentation

[Plan](../TASKS.md)

Status: Complete (static); runtime verification deferred
Complexity: High
Depends on: 03

## Objective and non-goals

Replace the parallel pending page-switch fields with a single presentation
request and restore the latest interaction policy when the page becomes ready.
Preserve document publication, operation ordering, and active-page semantics.

## Read before editing

- `ios/InkSignView+PageNavigation.swift`: `switchPage`,
  `documentViewPageDidChange`, `finishPageSwitchIfReady`, `cancelPendingPageSwitch`.
- `ios/InkSignView.swift`: pending page-switch fields and `PendingOpen`.
- `ios/InkSignView+MutablePages.swift`: structural suspension/publication,
  `resumeStructuralInteraction`.
- `ios/InkSignView+Document.swift`: install/close/failure/disposal callers.
- `ios/InkSignView+Overlay.swift`: attachment, reset, and readiness callbacks.
- `ios/InkSignView+Viewport.swift`: `completeOpenIfReady`, `viewportReadiness`.
- `.agents/skills/inksign-pdf-docs/references/swift-ios/view-lifecycle.md`.

## Preserved contract

Presentation is usable when the active PDF page, attached overlay, and transform
agree. Structural publication and document identity remain coordinator-owned.
Navigation retains prepared-page identity and mode-session authorization. Mode
requests made during suspension determine the resumed input policy.

## Implementation

1. Introduce a pending presentation request owned by the interaction coordinator:
   request identity, document/page identity, geometry revision, reason,
   optional viewport intent, and completion. Replace the corresponding standalone
   pending page-switch fields. Do not store a captured editing Boolean.
2. Route navigation, overlay replacement, and structural suspension notifications
   through the coordinator. Derive input availability from the current pending
   presentation and actual attachment facts.
3. Retain the distinct document open/publication operation and its error cleanup.
   Connect its readiness completion to the shared presentation boundary; do not
   merge document-operation lifetime with a viewport request.
4. On readiness, claim/remove the request before applying viewport changes or
   invoking callbacks. Apply current interaction policy, including the latest
   mode requested during suspension. Check request identity after reentrant calls.
5. On cancellation/failure, settle once and leave no stale completion or viewport
   intent. Replacement/disposal retires presentation, picker, and motion through
   one ordered coordinator entry while preserving document-worker cleanup.
6. Delete `pendingPageSwitchEditing` and superseded request fields/branches.
   Keep attachment facts needed to verify that PDFKit presents the correct page.

## Boundaries and completion

- A presentation request is view-local. It neither changes prepared-page
  identities nor cancels document mutations merely because the visible page changed.
- Keep document generation, mode token, and presentation request identity distinct.
- Done when readiness has one completion path, latest policy resumes, and every
  cancellation clears the owned request before calling external code.
- Static check: `git diff --check`; trace open, navigation, rotation, structural
  publication, replacement, and disposal. Integration verification: Task 05.
- Proposed commit: `refactor(ios): unify pending page presentation lifecycle`.

