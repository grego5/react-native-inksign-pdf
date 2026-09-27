# Limit and vertically anchor programmatic text on iOS

[Task index](../TASKS.md)

Status: Planned
Complexity: High

## Objective and non-goals

Implement the shared `TextAnnotationOptions.maxLines` and `verticalAnchor` for iOS imperative `addTextAnnotation()` after Task 02 adds the Nitro fields, changes the manual method signature, and regenerates bindings. Omitted or zero `maxLines` is unlimited; a positive value keeps at most the first N complete laid-out lines. `top` is the default and fixes the top edge at `position.y`; `bottom` fixes the retained block's bottom at `position.y` so added lines grow upward. Later source lines are omitted, including when the upper `yLimit` reduces available height.

Keep `xLimit`, page edges, direction-aware wrapping, font style, and the current native editor. Imperative `addTextAnnotation()` still accepts supplied text and clips its visible lines; it has no typing or caret acceptance step. When that annotation is reopened in an editor, edits must obey its stored limits. Task 05 will apply the same flow options to manual placement. Do not change Android or the no-options tap-placement geometry and rule snapping.

## Read before editing

- `Tasks/02-text-lines-vertical-anchor.md`, `src/InkSignView.nitro.ts`, and `src/index.ts`: shared option meanings, validation for both entry points, and generated Swift fields and method signature. Verify Task 02 is complete; never hand-edit `nitrogen/generated/**`.
- `ios/TextInteraction.swift`: `addTextAnnotation`, `showEditor`, `settledAnnotation`, `layoutEditor`; `ios/TextState.swift`: `InkSignPdfTextAnnotation` and its replace/move/font-size methods.
- `ios/TextRendering.swift`: line fragments, `visibleBounds`, and `drawCanonical`; `ios/PDFVectorAnnotation.swift`: text annotation coding and PDF appearance; `ios/NativePDFExporter.swift`: export verification.
- `ios/tests/InkSignViewTextInteractionTests.swift` and `ios/tests/SignatureExportTests.swift`: focused placement, editing, drawing, and export coverage.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`, `swift-ios/viewport-input.md`, `swift-ios/export.md`, and `development.md`.

## Current behavior and invariants

`addTextAnnotation` creates a page-space `flowBounds` from `position`, direction-aware `xLimit`, and lower `yLimit`. `InkSignPdfTextAnnotation` stores logical text, direction, visible bounds, and optional flow region. `TextRendering` lays out lines using TextKit, shows complete lines that fit the region, and supplies on-screen geometry and PDF drawing. Editing, moving, font-size changes, page history, and export must retain the chosen flow contract. The JavaScript host validates the new public option values before native dispatch.

## Implementation

1. In `TextInteraction.addTextAnnotation`, read the generated options and normalize the admitted `maxLines` and anchor. For `top`, require `0 <= position.y < page.height`, use `yLimit` or page bottom as the lower edge, and reject an empty or inverted region. For `bottom`, require `0 < position.y <= page.height`, use `yLimit` or page top as the upper edge, and reject an empty or inverted region. Preserve the existing horizontal interval and direction checks. Store the resolved line limit and anchor with the annotation; keep `flowBounds` as the hard page-space region.
2. Extend `InkSignPdfTextAnnotation` so the new values survive text replacement, move, font-size changes, page history, and edit commit. Preserve them when `PDFVectorAnnotation` copies or codes text appearance data. Existing tap-created annotations without a flow region retain their current behavior.
3. Give `TextRendering` one authoritative selection of complete line fragments in source order, constrained by both the flow height and positive `maxLines`. Derive visible bounds, on-screen drawing, and exported PDF appearance from that same selection. Expose the same layout result for editor fit checks, including directional wrapping within the hard horizontal region; do not substitute character counts or a second line-height estimate. For `bottom`, translate the retained block so its bottom meets `position.y` while staying inside `flowBounds`; for `top`, keep its top at `position.y`. Translation does not change which text fits. Do not crop a partial line or reverse reading order. Keep page clipping unchanged.
4. For a reopened annotation with a line, horizontal, or vertical limit, evaluate the prospective full text in the editor's text-change admission path before applying typing, paste, or replacement. Accept only changes whose resulting text fits in complete lines within the stored limits. Reject an overflowing insertion without changing text, selection, or caret. Always permit deletion and edits that reduce an already overflowing draft toward a fit. A direction or font-size change may reflow the existing text beyond the limits: retain that text and let the user edit it back into the region; never truncate it as a side effect of reflow. Keep `verticalAnchor` out of the fit decision.
5. Recompute visible bounds with the retained metadata after edit commit, move, and font-size changes. A reopened annotation must keep its flow and line settings; committed preview, hit bounds, and export must agree on the retained visible lines even if a reflowed draft was overfull. Update `README.md`, the architecture overview, and the owning iOS viewport/export references for implemented imperative behavior while stating that iOS manual options remain pending Task 05.

## Tests and verification

Use explicit line breaks with distinct first and later lines, fixed font, page, and flow width. Assert that bottom anchoring retains source order, grows upward while the bottom stays fixed, and omits a later line when `maxLines` is reached. Assert that an upper `yLimit` removes lines even with a larger `maxLines`; omitted/zero `maxLines` still obeys the geometric limit. Compare visible bounds and rendered appearance with the same expected line set, and check one exported PDF after reopen for appearance and selectable text order. Reopen a limited annotation and fill its last complete line: one more character, a newline, an overflowing paste, and an overflowing replacement leave text and caret unchanged; deletion succeeds and permits typing again. A direction or font-size change that reflows the text preserves it and permits deletion or replacement toward a fit. Exercise move and font-size change to verify both fields persist and bounds are recomputed. Preserve existing top-anchor, LTR/RTL, and tap-placement coverage. Inspect a representative rendered page in a graphics-capable simulator or device when available; use tolerant geometry rather than exact glyph pixels.

After the no-tests/builds restriction is lifted, run focused text-interaction and export tests through `IOS_TEST_ONLY` with `./tools/test-ios-mac-vm.sh` or the repository iOS runner, then inspect the representative page. Report the exact unrun gate if the Mac VM, simulator, or viewer is unavailable. Under the current restriction, perform static review and `git diff --check -- ':!nitrogen/generated/**'` only.

Complete when iOS imperative preview, hit bounds, bounded-editor edit admission, and exported PDF agree on the retained lines and vertical anchor, direct insertion still clips without rejecting text, existing unbounded text remains unchanged, and documentation accurately distinguishes pending iOS manual options. Proposed commit: `feat(ios): limit and vertically anchor programmatic text`.
