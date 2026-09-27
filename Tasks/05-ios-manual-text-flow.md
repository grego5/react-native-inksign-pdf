# Apply text flow options to manual placement on iOS

[Task index](../TASKS.md)

Status: Planned
Complexity: High

## Objective and non-goals

Implement the iOS behavior of `insertAnnotationOn(options?: TextAnnotationOptions)` after Task 04 establishes the annotation, renderer, and bounded-editor fit contract. A supplied options object applies the same `direction`, `xLimit`, `yLimit`, `maxLines`, and `verticalAnchor` rules as imperative `addTextAnnotation()`, using the placement tap as its canonical page position. A constrained editor accepts typing, paste, and replacement only when the resulting text fits as complete visible lines; deletion remains available. Omitted options preserve today's centered, rule-aware, unconstrained manual placement and editor behavior.

Do not change Android, imperative text admission, PDF page geometry, unrelated gestures, or the existing no-options placement contract.

## Read before editing

- `Tasks/02-text-lines-vertical-anchor.md` and `Tasks/04-ios-text-lines-vertical-anchor.md`: the shared public and iOS flow contracts. Confirm both are implemented before consuming the generated optional `insertAnnotationOn` argument.
- `src/InkSignView.nitro.ts` and `src/index.ts`: `insertAnnotationOn(options?)` and shared `TextAnnotationOptions` validation. Do not edit `nitrogen/generated/**` by hand.
- `ios/TextCommands.swift`: `insertAnnotationOn`; `ios/TextInteraction.swift`: `PlacementState`, `armPlacement`, `routePlacementTap`, `placeTextAt`, `makeInitialPlacement`, `showEditor`, `layoutEditor`, `settledAnnotation`, and `setTextDirection`.
- `ios/TextState.swift`: `InkSignPdfTextAnnotation`; `ios/TextRendering.swift`: selected visible lines and bounds from Task 04; `ios/tests/InkSignViewTextInteractionTests.swift`: centered placement, rule snapping, direction switching, editing, and placement lifecycle.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`, `swift-ios/viewport-input.md`, `swift-ios/export.md`, and `development.md`.

## Current behavior and invariants

Manual placement arms a one-shot tap tied to the current document generation and page. The tap creates a temporary editor whose initial box is centered horizontally, anchors its inner bottom to the tap or its outer bottom to a detected rule, and follows direction changes without moving the box at the instant of a switch. Only nonblank committed text enters page history. Task 04 supplies the stored line limit, vertical anchor, complete-line selection, and PDF rendering used by both entry points. The JavaScript host admits option values before native dispatch.

## Implementation

1. Accept the generated optional argument in `TextCommands.insertAnnotationOn` and pass it to `TextInteraction.armPlacement` on the main thread. Capture a supplied options object with the current generation and page when arming; do not reread mutable caller state at the later tap. Resolve its explicit direction or the existing `setTextDirection`/app-layout fallback at arm time. Preserve the existing no-op behavior when placement is already armed.
2. In `routePlacementTap`, convert the tap to canonical page coordinates before consuming placement. For supplied options, use the tap's x as the directional horizontal start and its y as the selected top or bottom edge. Resolve `xLimit` and `yLimit` or page-edge defaults with the same checks and error meaning as imperative admission. If the tap cannot define a non-empty flow region, leave the same placement armed so the next tap can succeed; do not open an editor, commit text, or change the document. For omitted options, keep the existing rule scan, snapping, and centered placement path.
3. For a valid options tap, create an editing state with the resolved hard page-space flow region, line limit, anchor, and direction. Size and place the live editor from the tap before showing it; use Task 04's same TextKit fit decision for prospective typing, paste, and replacement whenever `maxLines`, `xLimit`, or `yLimit` constrains it. An edit that would exceed complete visible lines leaves text and caret unchanged; deletion always works, including when one deletion still leaves the draft overfull after reflow. Choose the appropriate UIKit input mechanism while implementing the editor; extending marked text past a limit must not erase text already entered. The on-screen editor uses the same accepted text, wrapping, and bounds as committed preview and PDF appearance. Top anchoring keeps the top edge fixed as lines are typed; bottom anchoring keeps the bottom edge fixed and grows upward. `verticalAnchor` changes placement, not edit acceptance. Keep the hard horizontal edge and page bounds in both directions. Commit through `settledAnnotation` with the same metadata as imperative insertion, preserving logical text and reading order.
4. Keep active `setTextDirection()` behavior: update the editor's internal direction immediately without moving its frame at the switch, then use the selected direction for later expansion and viewport following. If a direction or font-size change reflows existing text beyond the available region, retain the text and allow deletion or replacement toward a fit; do not silently truncate it. Preserve the flow settings when the annotation is reopened, edited, moved, or its font size changes. Update `README.md`, the architecture overview, and the iOS viewport/export references so both entry points and both platforms are described as implemented.

## Tests and verification

Add a focused manual-placement case with explicit lines and supplied options: the tap defines the requested edge, the live editor and committed annotation keep the bottom edge fixed, the hard horizontal limit is respected, and `maxLines` and `yLimit` retain only complete fitting lines. Fill the final permitted line; one more character, a newline, an overflowing paste, and an overflowing replacement leave text and caret unchanged, while deletion permits typing again. Verify through the editor's actual UIKit input path that extending marked text past the limit preserves previously entered text and that Backspace makes progress after direction or font-size reflow even when the first deletion leaves the text overfull. Assert a tap outside the valid region leaves placement armed for a later valid tap. Check an edited/reopened annotation and representative PDF appearance against the same retained lines. Reuse the existing no-options centered placement, rule snapping, placement cancellation, and direction-switch tests as regressions; assert that supplying options does not alter those omitted-options results. Inspect a representative page on a graphics-capable simulator or device: fill the last permitted line, attempt another character and newline, then delete and type again. Use tolerant geometry expectations.

After the no-tests/builds restriction is lifted, run focused text-interaction and export tests through `IOS_TEST_ONLY` with `./tools/test-ios-mac-vm.sh` or the repository iOS runner, then inspect the representative page. Report the exact unrun gate if the Mac VM, simulator, or viewer is unavailable. Under the current restriction, perform static review and `git diff --check -- ':!nitrogen/generated/**'` only.

Complete when iOS manual and imperative paths share the line, anchor, and dimension contract, constrained edits stop at complete visible lines without blocking deletion or truncating reflowed text, the no-options manual path remains stable, preview and export agree, and documentation reflects both-platform support. Proposed commit: `feat(ios): apply text flow options to manual placement`.
