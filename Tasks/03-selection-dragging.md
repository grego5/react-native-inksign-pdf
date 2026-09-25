# 03 — Selection and immediate dragging

[Task index](../TASKS.md) · Status: Complete · Complexity: Medium

## Objective

An unselected annotation requires a long press to select, after which the held finger may drag. A selected annotation moves when a new touch inside its outline or box crosses touch slop, without another long press.

## Non-goals

No new selection mode, drag handle, history format, or change to ordinary viewport panning outside a selected annotation.

## Read before editing

- `android/src/main/java/com/margelo/nitro/inksignpdf/TextInteractionOverlay.kt`: `InteractionState.Selected/Dragging`, `LongPressDragTracker`, `handlePendingTouch`, `hitTest`, `beginDragging`, `dragAnnotation`, `commitDrag`, `cancelDrag`.
- `.agents/skills/inksign-pdf-docs/references/android/viewport-input.md`: touch ownership; `android/src/androidTest/kotlin/com/margelo/nitro/inksignpdf/TextPlacementInstrumentationTest.kt`: long-press, drag, and cancellation tests.

## Current behavior and invariants

The tracker currently enters `Dragging` only after its long-press timeout. Before that timeout, motion past touch slop routes the touch to viewport pan. `commitDrag` replaces one annotation once, creating one history action only for a changed position; cancellation leaves the annotation selected without a mutation. Tap edits text.

## Implementation

1. On touch down, use the shared box hit area from Task 02 and the selected annotation ID to choose the gesture route. For an already selected annotation, start a drag candidate immediately; apply movement only after touch slop, so a stationary tap still opens editing. Do not start a long-press timer for this route.
2. For unselected text, keep the long-press threshold. At the threshold, enter selected state and allow continued movement in the same held gesture to enter drag; release without movement leaves it selected. Preserve the pre-threshold movement-to-pan route.
3. Reuse the existing `dragAnnotation`, `commitDrag`, and `cancelDrag` transaction path. Ensure touch cancellation and page/document replacement cannot commit a move. Keep hit testing aligned with the rectangle drawn in Task 02.
4. Revise the Android viewport/input reference to describe the committed gesture contract.

## Tests and acceptance

- Cover long press/release selection, long press/move/release, immediate second-gesture selected drag, stationary selected tap opening the editor, pre-threshold unselected pan, cancellation, and one undoable history action per actual move.
- Test touches inside the visible box, including its padding, in both directions; selection must not alter the hit area.
- Run `tools\test-android.ps1 -Mode connected -Test com.margelo.nitro.inksignpdf.TextPlacementInstrumentationTest` when a compatible device is available, plus focused JVM text tests.

## Completion

Selection and dragging follow the two routes without duplicate history actions or lost viewport pan. Proposed commit: `fix(android): drag selected text without a second hold`.
