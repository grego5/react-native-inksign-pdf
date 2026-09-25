# 04 — Edit viewport and caret margin

[Task index](../TASKS.md) · Status: Complete · Complexity: High

## Objective

Entering Android text editing preserves zoom and pans to show as much of the text outline as possible. Caret following keeps both the caret and adjacent outline away from the screen edge, with a 24 dp margin in the usable viewport.

## Non-goals

No automatic fit-to-text zoom, change to normal page double-tap zoom, iOS viewport change, or guarantee that an outline wider than the screen is fully visible.

## Read before editing

- `android/src/main/java/com/margelo/nitro/inksignpdf/InkDocumentController.kt`: `focusTextForEditing`, `ensurePageRectVisible`, `doubleTapZoom`.
- `android/src/main/java/com/margelo/nitro/inksignpdf/PageViewport.kt`: `targetForTextEditing`, `ensurePageRectVisible`, usable viewport and focus allowance.
- `android/src/main/java/com/margelo/nitro/inksignpdf/TextInteractionOverlay.kt`: `placeTextAt`, `beginEditing`, `reconcileEditorPresentation`, `activeEditorLineBounds`, `editorBounds`; `.agents/skills/inksign-pdf-docs/references/android/viewport-input.md`.
- `android/src/test/kotlin/com/margelo/nitro/inksignpdf/PageViewportTest.kt` and `android/src/androidTest/kotlin/com/margelo/nitro/inksignpdf/TextPlacementInstrumentationTest.kt`.

## Current behavior and invariants

`focusTextForEditing` chooses at least `doubleTapZoom`; `targetForTextEditing` horizontally follows only the caret. Later reconciliation calls `ensureTextVisible` with 8 dp. The viewport uses the area remaining above the keyboard and may temporarily allow focus beyond ordinary page bounds so edge text remains reachable. The editor/page anchor must not be rewritten by viewport movement.

## Implementation

1. Keep `currentViewport.zoom` for edit entry. Replace caret-only entry targeting with a target based on the outer editor/annotation rectangle from Task 02 and the active caret. At fixed zoom, fit the whole outline within the usable width minus 24 dp on each side if it fits. If wider, position the viewport to show the greatest continuous portion around the active caret; keep the caret and its nearby outline at least 24 dp from the horizontal edge whenever the page permits.
2. Use the same 24 dp margin for caret follow in `reconcileEditorPresentation`. Include editor padding and outline stroke in the visible target, and use the keyboard-adjusted usable height for vertical visibility. Pan only; do not change text position or zoom. Preserve the existing animation ownership and temporary edge-focus allowance.
3. Update `PageViewportTest` expectations that currently encode caret-only edit entry. Update the Android viewport/input reference; update `README.md` only if it describes edit-entry zoom.

## Tests and acceptance

- At edit entry, assert zoom is unchanged for short and wide LTR/RTL text. Short text's entire outline fits inside a 24 dp margin; wide text displays the maximum feasible portion around the caret rather than leaving most text clipped by a needless zoom.
- With the keyboard visible and during caret movement, assert the caret and adjacent outline remain inside the 24 dp usable-screen margin when geometrically possible. Verify page anchors and annotation content remain unchanged by panning.
- Run `tools\test-android.ps1 -Mode jvm -Test com.margelo.nitro.inksignpdf.PageViewportTest`, focused text JVM and connected tests, `tools\test-android.ps1 -Mode jvm`, `tools\test-android.ps1 -Mode build`, `npx tsc --noEmit --pretty false`, and `git diff --check -- ':!nitrogen/generated/**'`. Run the full connected suite if a compatible device is available. Report unavailable validation explicitly.

## Completion

All four tasks meet their observable checks; no public API was added; current zoom, edge visibility, and saved text geometry remain consistent. Proposed commit: `fix(android): keep edit zoom and expose text around caret`.
