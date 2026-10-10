# 05 - Integrate, document, and review

[Plan](../TASKS.md)

Status: Complete (static); runtime verification deferred
Complexity: Medium
Depends on: 04

## Objective and non-goals

Finish removal of superseded paths, align existing checks and concise maintainer
contracts, and report what is statically established versus runtime-unverified.
Additional test coverage is not requested. Do not run tests/builds without new,
explicit user authorization.

## Read before editing

- Owners introduced by Tasks 01-04 and `ios/InkSignView.swift` assembly/disposal.
- `ios/History.swift`: `emitChange`; `ios/HybridModeSession.swift` and
  `ios/HybridAnalyzedPage.swift`: public delegation and lifetime checks.
- `ios/tests/InkSignViewLifecycleTests.swift`: mode-session cancellation,
  coordinate picking, structural latest-mode restoration, viewport settlement.
- `ios/tests/InkSignViewTextInteractionTests.swift`: deferred placement zoom,
  text lifecycle, caret geometry, selected-text handles.
- `ios/tests/InkSignViewPDFNavigationTests.swift`.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`:
  System boundaries and Document operations.
- `.agents/skills/inksign-pdf-docs/references/swift-ios/view-lifecycle.md` and
  `viewport-input.md`; `references/development.md`: iOS validation workflow.

## Implementation and static verification

1. Search for old mode, picker, viewport, inset, and pending-presentation fields.
   Remove duplicate ownership, unused forwarding helpers, and migrated callback
   paths. Derived read-only access may remain where it expresses a real boundary.
2. Inspect a mode change, field focus, manual placement, navigation, and disposal
   end to end. Each must reach one transition owner and one viewport writer.
   Confirm FIFO worker retention, callback reentry, and single promise settlement.
3. Adapt existing tests only where moved internal interfaces require it. Preserve
   observable expectations; do not maintain duplicate production state just to
   support private test access. If no adaptation is required, make no test edits.
4. Update the owning maintainer references in place. State final ownership,
   event/data flow, cancellation, and geometry contracts. Keep README unchanged
   unless the implementation unexpectedly requires a user-visible correction.
5. Run `git diff --check` and inspect public specs/generated files for accidental
   changes. No Nitrogen run is needed when the public interface is unchanged.

## Deferred runtime verification

Record these as pending, not as failures or successful verification:

- Existing lifecycle checks: session supersession cancels affected callers;
  cancellation retains a running worker's slot; structural completion applies
  the latest mode; document replacement/disposal settle pending work once.
- Existing picker checks: one consumed tap returns displayed page coordinates;
  page/mode/document cancellation preserves the established restoration rules.
- Existing viewport/text checks: focus reaches the requested clamped position;
  deferred placement zoom and editor layout keep their contracts; history and
  prepared-page handles survive navigation.
- Device inspection: simultaneous zoom/focus, typing/newline growth, caret
  following, pinch with keyboard visible then dismissal, ink, and module-text
  tap/long press. Check actual interaction instead of adding timing or pixel
  tolerances to force a green result.

When the user authorizes execution, follow the documented `ssh mac-vm` workflow,
sync/hash-verify sources, and use `bash ./tools/test-ios-mac-vm.sh` with the
narrowest applicable `IOS_TEST_ONLY` class or exact method selector including
`()`. Confirm nonzero executed cases. Do not reinstall Pods or repeat a build
without a changed input or a concrete runner requirement. Report unavailable
hosts/devices and retain useful failure output; no inferred pass.

## Completion

- Existing suite source references match the final owners; no additional coverage
  task is required for this refactor.
- Static ownership/lifecycle review and authored whitespace check are complete.
- References describe the implemented system, and public API remains compatible.
- Record runtime validation as pending while the user restriction remains active.
  A static completion must not claim the reported device issues are resolved.
- Proposed commit: `docs(ios): align viewer ownership contracts and integration`.


## Implementation result

- Interaction tokens, picker settlement, presentation requests, and input policy
  reside in `ViewerInteractionCoordinator`. Viewport mutation, motion, keyboard
  observations/insets, and settled zoom reporting reside in
  `ViewerViewportController`; hosts supply narrow domain/presentation adapters.
- Navigation and structural success/failure use the same readiness completion.
  Readiness requires the active PDF page, overlay, transform, window, and bounds.
  Completion claims the request and checks identity through reentrant callbacks.
- Cancellation retains running FIFO slots. New tokens replace old tokens before
  retiring callers; late motion and picker results require captured authorization.
  Framework gesture restoration precedes the coordinator's picker permissions.
- Existing lifecycle, navigation, text, and fixture source references migrated;
  observable assertions remain. No new tests were added.
- iOS lifecycle/input references describe the final ownership. Public API,
  generated bindings, README, and Android sources are unchanged.
- Authored `git diff --check` and obsolete-symbol/viewport-writer searches pass.
  Tests and builds were not run. The runtime checks listed above remain pending;
  the reported device interaction issues are not claimed resolved.
