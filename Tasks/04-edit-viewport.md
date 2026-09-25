# 04 — Edit viewport and caret margin

[Task index](../TASKS.md) · Status: Implemented; runtime validation pending · Complexity: High

## Objective

Entering iOS text editing keeps the current PDFView zoom and pans to show as much of the editor outline as possible. Later caret movement keeps caret and adjacent outline away from the usable viewport edge with a 24-point screen-space margin when feasible.

## Non-goals

No automatic fit-to-text zoom, change to normal PDFView double-tap, rewrite of annotation position during panning, or promise that an outline wider than the viewport fits entirely.

## Read before editing

- `ios/TextInteraction.swift`: `showEditor`, `layoutEditor`, `followCaretIfNeeded`, `keyboardFrameChanged`, `updateKeyboardOcclusion`.
- `ios/InkSignView+Viewport.swift`: `ensureTextVisible`, `panViewport`, `setTextKeyboardOcclusion`, PDFDestination navigation; `ios/InkSignView.swift`: PDFView configuration.
- `.agents/skills/inksign-pdf-docs/references/swift-ios/viewport-input.md`; `ios/tests/InkSignViewLifecycleTests.swift`: zoom/viewport checks.

## Baseline before implementation

The editor follows only a slightly expanded caret through `ensureTextVisible(..., padding: 8)`. That method pans PDFView at its current scale using a keyboard-reduced visible area. Editor and annotation positions are canonical page coordinates; viewport movement cannot mutate them.

## Implementation

1. At editor entry, retain `documentView.scaleFactor`. Use Task 02's outer editor rectangle plus caret to choose a fixed-scale pan target within the keyboard-adjusted visible container. If the full outline fits with 24 points on each side, show it; if wider, expose the greatest useful continuous area around the caret. Do not change zoom or saved page position.
2. Use the same 24-point screen margin on text/selection and keyboard-frame changes. Include outline stroke/padding. Follow vertically and horizontally. Keep viewport panning in `InkSignView`, not PDFView's internal scroll hierarchy.
3. Preserve the existing document/page guard on viewport movement. Editing does not invoke view-mode double-tap zoom. Update the iOS reference and README only where they describe edit visibility or zoom.

## Tests and acceptance

- Add a deterministic viewport-target contract only if separable from PDFView internals: zoom unchanged, short outline inside usable margins when feasible, wide outline exposed around caret, and canonical annotation position unchanged.
- On simulator/device, test short and wide LTR/RTL text at multiple zooms and page edges, keyboard shown/hidden, and caret movement. Inspect smooth panning without editor jumps or zoom changes.
- Run focused iOS text and lifecycle XCTest on macOS, `tools\test-ios-lifecycle.ps1`, `npx tsc --noEmit --pretty false`, and `git diff --check -- ':!nitrogen/generated/**'`. Report unavailable Xcode/device checks.

## Completion

All four tasks meet their observable contracts without new public API; zoom and saved text geometry stay stable as editing remains visible. Proposed commit: `fix(ios): keep edit zoom and expose text around caret`.
