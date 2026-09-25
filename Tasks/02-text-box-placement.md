# 02 — Text box and caret placement

[Task index](../TASKS.md) · Status: Implemented; runtime validation pending · Complexity: Medium

## Objective

Make idle, selected, and editing text outlines use one outer rectangle. A new empty box starts about one character wide, and the placement tap indicates the initial caret content edge rather than the box center.

## Non-goals

No font-size change, export-coordinate change, persisted outline padding, or Android layout change.

## Read before editing

- `ios/TextInteraction.swift`: `placeTextAt`, `showEditor`, `layoutEditor`, `measureEditor`, `outlineBounds`, `annotation(at:)`, `draw`, `settledAnnotation`.
- `ios/TextRendering.swift`: `InkSignPdfTextStyle.presentationInsets` and renderer measurement; `ios/TextState.swift`: annotation bounds; `ios/tests/InkSignViewTextInteractionTests.swift`.
- `.agents/skills/inksign-pdf-docs/references/swift-ios/viewport-input.md`: canonical and presentation coordinates.

## Baseline before implementation

`showEditor` centers a new box on the tap. Empty editor width can shrink to a device pixel. Editing draws `editor.frame`, while idle/selected outlines derive from transformed annotation bounds; hit testing has a separate minimum target. Stored bounds remain canonical page units.

## Implementation

1. Use one one-em minimum empty content width, capped by available page width; retain TextKit-measured width for nonempty text. Keep the final TextKit container width, caret, and selection layout synchronized as the editor grows.
2. Interpret placement as first-line caret content start: LTR left or RTL right at the tapped vertical start. Account for `presentationInsets` and page-to-overlay transform. Clamp the box to the page, then derive the saved content anchor from that frame. Do not center on the tap.
3. Keep committed bounds and live editor in the same canonical content geometry. Derive idle and selected outlines from one outer-rectangle calculation with consistent screen-space padding and stroke at the current scale. Use the same visible rectangle for selection hit testing; keep presentation padding out of persisted bounds.
4. Update the iOS viewport/input reference and README placement statement after implementation.

## Tests and acceptance

- Add a small deterministic contract for content-to-outline conversion, tap-to-anchor placement, and page-edge clamping in LTR/RTL. Do not use pixel-perfect automated assertions for caret/font visual fidelity.
- On simulator/device, place text near center and edges at two zooms; compare caret, editor outline, committed outline, and selected outline. The tap should land at the caret edge unless clamped.
- Run `tools\test-ios-lifecycle.ps1` and focused text XCTest on macOS; report unavailable checks.

## Completion

The box starts near one em, follows the placement caret, and keeps one outline geometry through edit, commit, and selection. Proposed commit: `fix(ios): align text outlines and placement caret`.
