# Task 04: Rebuild text editor layout

[Back to task index](../TASKS.md)

Status: Complete

## Objective

Replace the mixed UIKit/canonical sizing model with one canonical text-layout
authority so annotations remain page-attached, stable across edit/blur cycles,
immediately responsive to newlines, and visibly editable.

## Non-goals

- Do not add rich text, manual resizing, or new public styling properties.
- Do not change committed text history or export semantics.

## Read before editing

- [Task 01](01-unify-ios-page-transform.md) and its implemented transform.
- `ios/TextInteraction.swift`: editor lifecycle, `layoutEditor`, hit testing,
  dragging, and keyboard avoidance.
- `ios/TextRendering.swift`: intrinsic measurement and canonical drawing.
- `ios/TextState.swift`: immutable annotation bounds.
- Android `TextInteractionOverlay.kt` and `TextLayout.kt` for behavioral parity.
- Maintainer references `references/architecture.md`,
  `references/swift-ios/viewport-input.md`, and
  `references/swift-ios/history.md`.

## Current behavior and invariants

Committed text uses explicit newlines and intrinsic longest-line sizing in
canonical coordinates. The live editor currently mixes page-space bounds,
UIKit text-container measurement, padding, and transforms, causing viewport
drift, repeated blur resizing, clipped new lines, and hidden overflow.

## Implementation

1. Add `TextLayoutMetrics` to `ios/TextRendering.swift` and make
   `InkSignPdfTextRenderer.layout(text:fontSize:)` its sole constructor. It
   returns explicit lines, maximum line width, line height, and total canonical
   size. Width comes from the longest explicit line; height is `lineHeight`
   multiplied by `text.components(separatedBy: "\n").count`, which preserves a
   trailing empty line.
2. Separate canonical content bounds from presentation-only editor padding,
   caret accommodation, background, and outline. Never feed padded UIKit
   bounds back into `InkSignPdfTextAnnotation`.
3. Configure the editor with no soft wrapping or scrolling. On
   every `textViewDidChange`, compute canonical content size, derive the
   transformed editor frame, force text-container layout, then follow the
   updated caret.
4. Derive the editor's canonical bounds from `TextLayoutMetrics`, add UIKit
   insets only when producing its view frame, and never read `UITextView.bounds`
   back into model state.
5. Project committed text, the editor, outlines, selection, hit regions, and
   drag deltas through Task 01's current transform. A viewport change invokes
   one synchronization path for all of them.
6. Draw a two-point dashed edit outline using the existing outline-color presentation
   contract. Keep it distinct from selected and committed-annotation outlines;
   do not add a public prop.
7. Commit blur using canonical intrinsic bounds only. Reopening and blurring
   unchanged content must not create a history action or modify bounds.
8. Preserve Android-equivalent LTR/RTL anchoring, page-edge clamping, empty
   draft removal, and keyboard/caret avoidance.
9. Delete superseded measurement and frame-feedback paths. Do not retain them
   behind conditionals for compatibility with previously incorrect bounds.

## Rules

- Temporary editor and selection state remain outside history and export.
- Text gestures do not enter PDF navigation or ink streams.
- Font size remains annotation-local canonical data and scales only through
  viewport presentation.
- One completed edit creates at most one history action.
- Existing tests or documentation that normalize UIKit-derived bounds,
  repeated blur drift, soft wrapping, or viewport-fixed placement must be
  replaced rather than accommodated.

## Tests

- Add canonical layout and editor-projection cases to
  `InkSignViewStabilizationTests`. Keep keyboard/visual behavior that requires
  a physical device in the manual acceptance list rather than CI.
- Repeated edit/blur cycles preserve identical text, position, and bounds and
  create no extra history entries.
- Long lines expand horizontally and remain visible without soft wrapping.
- A newline and a trailing empty line expand height immediately.
- The caret stays visible after each line is created.
- The editing outline appears only for the live editor.
- Text, editor, selection, hit testing, and dragging remain aligned after pan
  and zoom.
- Cover LTR, Hebrew/RTL, empty drafts, page edges, font-size changes, and
  keyboard avoidance.

## Validation

Perform static review only: trace all annotation-size construction to
`TextLayoutMetrics`, confirm no model value is derived from `UITextView.bounds`,
and verify every transform/hit-test path uses Task 1's mapping. Do not run iOS
tests locally or retain the old layout path. Task 5 owns compilation and
runtime keyboard validation.

## Completion criteria

- Text remains attached to page content through every viewport mutation.
- Blur is idempotent, explicit lines are immediately visible, and overflow is
  not hidden by stale editor bounds.
- The canonical text-layout authority fully replaces the old feedback model;
  integrated visual and interaction acceptance is owned by Task 5.

Proposed commit: `fix(ios): stabilize canonical text editing layout`
