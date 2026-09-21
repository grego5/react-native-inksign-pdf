# Task 03: Correct mode and ink routing

[Back to task index](../TASKS.md)

Status: Complete

## Objective

Prevent transient unsaved ink in view mode, restore double-tap zoom, and keep
committed ink attached to the page across later viewport changes.

## Non-goals

- Do not support pinch or pan while drawing.
- Do not replace PencilKit or change public pen configuration.

## Read before editing

- [Task 01](01-unify-ios-page-transform.md) and its implemented transform.
- `ios/PageOverlay.swift`: `InkCanvasView`, hit testing, and drawing recognizer.
- `ios/InkSignView+Document.swift`: `setInteractionMode`.
- `ios/InkSignView+Viewport.swift`: mode transitions and double-tap behavior.
- `ios/InkInput.swift`: transaction ownership and canonical/display drawing.
- Maintainer references `references/swift-ios/viewport-input.md`,
  `references/swift-ios/rendering.md`, and `references/swift-ios/history.md`.

## Current behavior and invariants

View mode should own pan, pinch, double-tap, and navigation; edit mode should
own drawing. The canvas must remain present for committed ink and nested text
interaction, so disabling the entire canvas is not a valid mode switch.
PencilKit live width is screen-relative, while committed drawings are stored
in canonical page coordinates and reprojected for display.

## Implementation

1. Make `setInteractionMode(editing:)` the sole mode owner. It atomically
   configures PencilKit drawing, document pan/pinch/double-tap, edge navigation,
   and text lifecycle. Remove direct mode-related recognizer toggles from other
   callers after they route through this method.
2. In view mode, disable drawing input and enable viewport, double-tap, and
   navigation recognizers. In edit mode, enable drawing only after the page and
   transform are ready and disable viewport/navigation recognizers.
3. Cancel live ink before mode, viewport, page, generation, background, overlay
   detachment, or disposal transitions. Cancellation restores the committed
   drawing and creates no history action.
4. Freeze Task 01's transform snapshot for each stroke transaction. Convert
   the completed PencilKit drawing through its inverse into canonical page
   space exactly once.
5. Reinstall committed canonical drawing through the latest transform after
   each accepted viewport mutation, preserving constant on-screen live brush
   width but allowing committed ink to scale with later viewport changes.
6. Model transaction identity so late PencilKit callbacks cannot belong to the
   current state. A stale callback restores committed content at the delegate
   boundary; do not add per-caller defensive exceptions.

## Rules

- A completed stroke records exactly one page-history action.
- Prediction and cancelled live geometry never enter history or export.
- Text-owned touches remain outside PencilKit and viewport gesture streams.
- Pen changes during a stroke retain the existing queued-update behavior.
- Old recognizer-order tests are not compatibility contracts. Rewrite them
  when they conflict with the single mode owner or correct input isolation.

## Tests

- Add focused mode and transaction cases to
  `InkSignViewStabilizationTests`; do not rerun unrelated stable lifecycle
  cases in the final workflow.
- View-mode finger and Pencil touches cannot change visible or committed ink.
- Double-tap and pinch work in view mode and do not enter drawing callbacks.
- Edit-mode input records exactly one undoable action per completed stroke.
- Cancelled and stale callbacks create no history.
- Committed ink moves and scales correctly after leaving edit mode and changing
  the viewport.
- Text placement and editing remain reachable with drawing disabled.

## Validation

Perform static review only: enumerate every assignment to recognizer enabled
state and prove it is either initialization/reset or owned by
`setInteractionMode(editing:)`; trace every stroke exit to cancellation or one
commit. Do not run iOS tests locally. Task 5 owns compilation and runtime input
validation.

## Completion criteria

- Mode ownership matches Android.
- View mode cannot show disposable PencilKit strokes.
- The single mode owner and canonical ink flow are implemented; integrated
  gesture acceptance is owned by Task 5.

Proposed commit: `fix(ios): enforce viewport and ink gesture ownership`
