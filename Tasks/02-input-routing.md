# 02 - Own input routing and coordinate picking

[Plan](../TASKS.md)

Status: Complete (static); runtime verification deferred
Complexity: Medium
Depends on: 01

## Objective and non-goals

Make picker lifecycle and input permissions follow the interaction coordinator.
Preserve existing gestures and picker restoration behavior; add no gesture modes.

## Read before editing

- `ios/InkSignView+Viewport.swift`: `pickPageCoords`, `cancelCoordinateRequest`,
  `restoreCoordinateMode`, `handleCoordinateTap`, `coordinateTargetIsCurrent`.
- `ios/InkSignView.swift`: `CoordinateRequest`, `CoordinateTarget`,
  `InkSignPdfViewGestureDelegate`, coordinate recognizer.
- `ios/InkSignView+Document.swift`: `configureCanvasInteraction`,
  `updatePDFViewInteractionOwnership`, `applyInteractionMode`.
- `ios/PDFViewInteractionOwnership.swift`: `update`, suppression/restoration.
- `ios/PageOverlay.swift`: canvas/overlay hit testing and canvas creation.
- `ios/TextInteraction.swift`: hit testing and gesture admission.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`: picker lifecycle.

## Preserved contract

A coordinate request captures document/page/geometry identity and consumes one
valid tap. Pan/pinch do not select. Page/geometry/mode changes and teardown cancel
it. Direct calls finish in view; session calls restore their originating mode
when the token remains valid. Interactive waiting releases the FIFO queue.

## Implementation

1. Move the pending picker and its settlement/restoration logic into the
   interaction coordinator. The recognizer supplies a converted tap and page
   identity; it does not perform an independent mode change.
2. Clear picker ownership before restoring mode or resolving/rejecting its
   promise. A superseding mode request prevents restoration of the old mode.
3. Derive one input policy from current activity and presentation availability.
   Apply it to PDFKit, text recognizers, and the active canvas. Eliminate cached
   `viewInteractionsEnabled` as an independent authority.
4. Keep `PDFViewInteractionOwnership` as a policy application helper. Preserve
   markup overlay hit testing and the existing gesture precedence. Its saved
   framework states are restoration data, not another mode model.
5. Configure newly attached/replaced overlays from the current policy. Text
   overlays yield ink touches; canvases yield outside ink. Module text remains
   selectable/editable through its overlay in the applicable modes.
6. Remove old picker fields, restoration branches, and duplicate readiness/mode
   checks after all production callers use the coordinator boundary.

## Boundaries and completion

- Input availability may temporarily suspend the requested mode during document
  installation. Availability does not replace the mode-session token.
- Keep public tap coordinates in displayed page points; use the existing adapter
  to confine PDFKit coordinates to the boundary.
- Done when every input-policy update comes from the coordinator, overlays
  inherit it on attachment, and picker settlement/restoration has one owner.
- Static check: `git diff --check`; trace direct/session picker success,
  navigation cancellation, supersession, and disposal. Task 05 owns integration.
- Proposed commit: `refactor(ios): unify input policy and coordinate picking`.

