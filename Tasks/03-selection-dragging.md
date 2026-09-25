# 03 — Selection and selected-text dragging

[Task index](../TASKS.md) · Status: Implemented; runtime validation pending · Complexity: Medium

## Objective

Long-press unselected text to select and optionally drag it in the same hold. Once selected, a new touch inside its visible box can drag without another long press; a stationary tap still opens editing.

## Non-goals

No new selection mode, drag handle, history format, or change to PDFView navigation outside text hit areas.

## Read before editing

- `ios/TextInteraction.swift`: `tapRecognizer`, `dragRecognizer`, gesture delegate, `handleTap`, `handleLongPress`, `selectForDrag`, `commitDrag`, `annotation(at:)`.
- `ios/InkSignView+Document.swift`: `updatePDFViewInteractionOwnership`; `ios/InkSignView+Viewport.swift`: PDFView input ownership; `.agents/skills/inksign-pdf-docs/references/swift-ios/viewport-input.md`.

## Baseline before implementation

`UILongPressGestureRecognizer` always owns dragging with a 0.5-second hold. `handleTap` opens the editor. `commitDrag` records one text-move history action only for a changed position; cancellation adds none. The overlay intercepts annotation touches while PDFView owns ordinary navigation in view mode.

## Implementation

1. At touch admission, distinguish selected from unselected text using Task 02's visible rectangle. For selected text, start an immediate movement candidate; move only after a small gesture threshold so a stationary tap still edits. No long-press delay on this route.
2. Retain long press for unselected text. Once recognized, select and let continued motion in the same hold drag; release without movement leaves selection. Before recognition, preserve ordinary PDFView/presentation gesture ownership.
3. Route both movement paths through one `DragState` and existing `commitDrag`/cancel lifecycle. Verify document generation and active page before commit. Cancellation or page/document replacement cannot add a move.
4. Update the iOS viewport/input reference with the gesture contract.

## Tests and acceptance

- Keep an automated state/history check for one undoable move on changed position and no action for stationary, cancelled, or stale movement. Avoid synthetic timing tests that merely imitate UIKit recognizers.
- Manually verify long-press selection, hold-and-drag, immediate selected drag, stationary selected tap-to-edit, PDF navigation outside text, and cancellation on simulator/device. Include LTR/RTL and visible padding.
- Run `tools\test-ios-lifecycle.ps1` and focused text XCTest on macOS; report unavailable checks.

## Completion

Both gesture routes share one move transaction and do not steal unrelated PDFView navigation. Proposed commit: `fix(ios): drag selected text without another hold`.
