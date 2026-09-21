# Task 05: Integrate and validate iOS stability

[Back to task index](../TASKS.md)

Status: In Progress

## Objective

Complete any disclosed transitive migration from Tasks 1 through 4, restore a
coherent build, validate the combined PDF, viewport, ink, and text behavior,
and align maintainer references with the implemented invariants.

## Non-goals

- Do not alter Android behavior. A public iOS/API break is allowed only when a
  completed preceding task establishes that the existing contract prevents the
  coherent architecture; document the replacement and migration explicitly.
- Do not claim runtime success from static checks alone.

## Read before editing

- Completed Tasks 01 through 04 and their focused tests.
- `diagnostics/RaDaLqz0kjfZbrgDjeEd.pdf` and the reported screenshot.
- Maintainer references `references/swift-ios/rendering.md`,
  `references/swift-ios/viewport-input.md`, and
  `references/swift-ios/configuration-validation.md`.
- `tools/test-ios-lifecycle.ps1` and relevant repository validation runners.

## Current behavior and invariants

The public API and intended architecture already specify canonical content,
bounded presentation state, generation-bound workers, and mode-separated input.
Documentation should describe the final implemented state rather than the
transition or prior defects.

## Implementation

1. Resolve the intentional intermediate compile/test failures disclosed by
   Tasks 1 through 4 by completing caller migration to the final abstractions;
   remove any temporary compatibility code encountered.
2. Exercise the diagnostic PDF on iOS and compare it with Android for page
   orientation, Hebrew direction, page framing, text placement, and ink
   placement.
3. Stress fit-to-16x zoom, pan, double-tap, mode changes, drawing, multiline
   text editing, navigation, document replacement, backgrounding, and disposal.
4. Observe memory and request activity during zoom stress. Confirm tile cache,
   pending work, and replacement presentation remain bounded.
5. Verify export uses committed canonical ink and text and preserves placement
   independently of the final viewport.
6. Update the iOS rendering reference with implemented tile allocation,
   request-cancellation, cache, and fallback-presentation invariants.
7. Update viewport/input and validation references only for stable ownership,
   lifecycle, or required validation facts established by the implementation.
   Do not add a changelog or duplicate existing architecture statements.
8. Leave README and Nitro API sources unchanged because the user-facing
   contract is expected to remain sufficient. If implementation proves that
   assumption false, update the authoritative Nitro source, regenerate output,
   document the intentional break, and add migration validation instead of a
   compatibility shim.
9. Audit existing iOS tests and maintainer references against the corrected
   design. Rewrite or delete obsolete expectations; do not preserve interop
   with incorrect historical implementation behavior.
10. Add a manually dispatched `.github/workflows/ios-validation.yml` because
    no current workflow executes the pod's `LifecycleTests` test spec. Use a
    macOS runner to install the example consumer, fetch PDFium, generate the
    iOS workspace, install pods, require the lifecycle-test scheme to exist,
    and run `xcodebuild build-for-testing` once for the complete native module
    and test bundle on an available iOS Simulator.
11. Give `workflow_dispatch` one required `focus` choice input with these exact
    values and mappings:
    - `stabilization` (default): compile the full module, then use
      `-only-testing` for `InkSignViewStabilizationTests` only.
    - `pdfium`: compile the full module, then run `PdfiumSmokeTests` only.
    - `lifecycle`: compile the full module, then run
      `InkSignViewLifecycleTests` only.
    - `all`: compile once, then run all three classes.
    - `build-only`: compile the full module without executing tests.
12. Implement the mapping in one small shell `case` statement that produces
    the Xcode arguments. Reject every unknown value. After `build-for-testing`,
    use Xcode test enumeration in JSON format and require each selected class
    to appear before invoking `test-without-building`; a typo must not silently
    produce a testless pass.
13. Do not archive, sign, export an IPA, run the ad-hoc workflow, install on a
    device, or run Android, native C++, TypeScript, or unrelated repository
    suites in this workflow. Upload the Xcode result bundle and log on failure.
14. After local static review and all code, tests, and documentation are final,
    dispatch the workflow exactly once with `focus=stabilization`. Do not run
    `all` for this change. Fix failures on the same architecture; do not
    introduce compatibility paths merely to satisfy the worker.

## Rules

- Each documentation claim must be supported by code, focused tests, or an
  explicitly maintained contract.
- Review the final design for redundant state, duplicated transforms, silent
  fallbacks, and guards that mask ownership violations; remove them before
  declaring completion.
- Treat current code and tests as evidence to investigate, not authorities over
  the agreed architecture. The updated contract and correctness invariants are
  authoritative after this work.
- Worker results remain generation- and page-bound detached values.
- Runtime checks require macOS/Xcode and the relevant simulator or device.

## Tests and scenarios

- Open the diagnostic PDF and verify upright, unmirrored base content.
- Repeatedly alternate fit, double-tap zoom, pinch to maximum, and pan with no
  white flashing, crash, or stale tile installation.
- Draw, leave edit mode, and zoom; committed ink must remain aligned and scale.
- Create LTR and RTL multiline annotations, blur repeatedly, zoom, pan, drag,
  undo/redo, navigate away/back, and export; content and bounds remain stable.
- Replace and dispose documents while tile, keyboard, or drawing work is
  active; no old-generation result reaches the new view.

## Validation

First perform only the relevant inexpensive local static pass:

```powershell
tools\test-ios-lifecycle.ps1
tools\check-text-test-contract.ps1
git diff --check -- ':!nitrogen/generated/**'
```

These commands validate source contracts only and must not be reported as an
iOS build or runtime result. After they pass, dispatch the new iOS validation
workflow once and use its final Xcode build/test result as the sole automated
macOS result. Use `focus=stabilization`; do not run stable legacy suites simply
for broad coverage. The other focuses are reusable diagnostics, not required
acceptance for this change.
Physical-device visual/gesture stress remains a later manual acceptance step
and must be reported as pending until actually performed.

## Completion criteria

- The full iOS module compiles and `InkSignViewStabilizationTests` passes in the
  single final GitHub Actions run with `focus=stabilization`.
- No out-of-scope Android or public API source is changed; history, export, and
  lifecycle invariants touched by the new architecture are covered by focused
  static review or stabilization tests.
- Maintainer references describe the verified implementation without historical
  commentary.

Proposed commit: `test(ios): validate PDF and annotation stability`
