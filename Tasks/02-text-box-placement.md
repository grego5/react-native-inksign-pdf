# 02 — Consistent text box and caret placement

[Task index](../TASKS.md) · Status: Complete · Complexity: Medium

## Objective

Make idle, selected, and editing outlines share the same outer geometry. Start a new empty box at approximately one character of content width, and make the placement tap indicate the initial caret content start rather than the box center.

## Non-goals

No change to text font size, export coordinates, iOS layout, or gesture policy. Do not make the persisted annotation bounds include presentation padding.

## Read before editing

- `android/src/main/java/com/margelo/nitro/inksignpdf/TextInteractionOverlay.kt`: `textEditorIntrinsicSize`, `editorSize`, `chooseTextPlacementPosition`, `placeTextAt`, `textOutlineRect`, `textPresentationRect`, `editorBoundsFor`, `layoutEditorFrame`, `annotationAt`.
- `android/src/main/java/com/margelo/nitro/inksignpdf/TextLayout.kt`: text measurement and render bounds; `.agents/skills/inksign-pdf-docs/references/android/viewport-input.md`: canonical coordinates.
- `android/src/test/kotlin/com/margelo/nitro/inksignpdf/TextInteractionContractTest.kt` and `android/src/androidTest/kotlin/com/margelo/nitro/inksignpdf/TextPlacementInstrumentationTest.kt`: placement/outline coverage.

## Current behavior and invariants

The empty editor minimum width is four font sizes. `chooseTextPlacementPosition` subtracts half the box width/height from the tap. `textOutlineRect` applies different padding for selected and idle annotations, so selection changes the visible dimensions. Annotation bounds remain canonical page units; editor padding and outline stroke are presentation pixels. RTL is anchored at the right content edge.

## Implementation

1. Replace the four-font-size empty width in both intrinsic and native editor measurement with a one-em minimum content width, bounded by the available page width. Keep one source for that minimum so the initial editor and later reconciliation agree.
2. Make `placeTextAt` interpret the tapped page point as the caret content origin: the LTR content left edge or RTL content right edge, and the first line's caret top. Offset the visible editor frame by its existing padding; clamp only as required to keep the box on the page. Recompute the saved content anchor from the clamped frame so the displayed caret and eventual annotation position agree. Do not recenter around the tap.
3. Derive idle and selected outer outlines from the same content bounds and editor-equivalent pixel padding at the current zoom. Only paint color, stroke, and optional fill may differ. Use that same rectangle in hit testing. Preserve the PDF/page-unit content bounds without padding.
4. Update the Android viewport/input reference and the user-facing placement description in `README.md` after implementation.

## Tests and acceptance

- Assert idle and selected outline rectangles have the same edges at multiple zooms for LTR and RTL. Compare them with the visible editor frame after committing and reopening unchanged text.
- For new placement, assert the first caret content edge maps to the tap in both directions when the box fits; near page edges assert the clamped frame and caret remain aligned. Assert the empty content minimum is one em rather than four.
- Run `tools\test-android.ps1 -Mode jvm -Test com.margelo.nitro.inksignpdf.TextInteractionContractTest` and the focused connected `TextPlacementInstrumentationTest` when available.

## Completion

Selection no longer changes outline dimensions; one-character-width placement aligns the caret with the tap except for necessary page-edge clamping. Proposed commit: `fix(android): align text outlines and placement caret`.
