# Verify coordinate identity and presentation
[Plan](../TASKS.md)

Status: Planned
Complexity: High

## Objective and scope
Add focused regressions for Tasks 01–04 and perform runtime validation when authorized. Tests and builds remain deferred under the existing user restriction.

## Read before editing
Android PageCoordinatesTest, TextPlacementInstrumentationTest, HybridInkSignViewTextKeyTest, PageRotationInstrumentationTest, PdfiumSmokeInstrumentationTest; existing prepared-page fixture support.
iOS ios/tests/InkSignViewTextInteractionTests.swift, InkSignViewLifecycleTests.swift, PlacementRuleDetectorTests.swift and SignatureExportTests.swift.
Workflow: .agents/skills/inksign-pdf-docs/references/development.md and platform validation references.

## Regression work
Use existing deterministic fixtures and observable geometry/history invariants:
1. Free identity: resolve a noncentral rectangle, rotate 180°, resolve its projected physical location and obtain the same ID. Resolve the original numeric rectangle in the new orientation and obtain a distinct target; writing each affects its own location.
2. Named identity: resolve an empty field, rotate 180° and resolve the eligible field again; ID is stable and insertion is upright in current display. Quarter-turn vertical rules reject new creation/focus without changing history. Existing committed text remains readable/editable/clearable.
3. Initial source rotation and nonzero media-box origin: verify point/rectangle mapper round trips and one actual insertion/focus/export using a known fixture. Use exact geometric expectations with pixel-rounding tolerance only where rasterization requires it.
4. Local layout: existing multiline annotations preserve identity, line breaks and wrapping through rotation, editing, undo/redo and finalize. Manual dragging after rotation updates canonical placement; subsequent free resolution agrees with the accepted physical location.
5. Values: named top/bottom detection excludes only selected label glyph ranges; free bounds detect source text. Include one source-interleaved label/value fixture to catch broad interval exclusions. Module writes override source and clear reveals it; adjacent fields remain separate.
6. Formatting: change vertical anchor and line cap through the prepared API, then check rendered visible bounds, hit testing and selection agree. Preserve one existing composing-input regression rather than adding a gesture/IME variation grid.
7. Focus: named focus uses the actual writing rule for either text anchor; free focus uses center. Preserve zoom/offset/anchor and captured-page navigation behavior.
8. Export: use existing calibrated renderer/extraction checks to prove one rotation application, text presence and placement. Keep channel-format assumptions explicit; use an independent renderer only to resolve an actual discrepancy.
9. Existing lifecycle cases prove replacement/deletion/disposal invalidation and inactive-page writes. Retain analysis count checks that demonstrate no new PDF scans during synchronous operations.
Consolidate equivalent existing cases instead of adding duplicate predicates or timing assertions.

## Validation
While restricted: inspect focused diffs, verify task links, and run git diff --check. Add/update regression source without running tests/builds.
After authorization:
- tools/test-android.ps1 -Mode jvm -Test <changed focused class>
- tools/test-android.ps1 -Mode build -Abi x86_64
- tools/test-android.ps1 -Mode connected -Abi x86_64 -Test <changed focused class>
- Use the documented Mac workflow with verified source hashes and IOS_TEST_ONLY for changed iOS suites.
- Run public API/TypeScript checks only if their surface or callers changed. Nitrogen is needed only for an interface change.
Use the documented host execution context. Record device/ABI, source identity, commands, and actual results. Installation failure/offline emulator/unavailable Mac are environment limits, not passing assertions.

## Completion
Record deterministic coverage and remaining limits separately. Runtime completion requires the focused geometry/export/lifecycle checks on both platforms; no performance claim is inferred from fewer conversions.
Proposed commit: Verify canonical target identity and rotated presentation

