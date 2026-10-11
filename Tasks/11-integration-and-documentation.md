# 11 — Verify cross-platform workflows and document the contract

[Plan index](../TASKS.md)

Status: Planned
Complexity: High
Dependencies: 10

## Objective and non-goals

Establish end-to-end evidence for the agreed workflow and update user/maintainer documentation to the implemented state. Do not broaden format support, add global caches, or add unrelated PDF editing features.

## Read before editing

- Completed tasks 01–10 and their recorded evidence; exported source specs/index.
- Existing Android/iOS headless, font-registry, text-placement, lifecycle and export tests plus test fixtures.
- README public usage sections located with rg.
- Maintainer architecture, Android lifecycle/export, Swift lifecycle/export, and development/validation references.
- `tools/test-android.ps1`, `tools/test-ios-mac-vm.sh`, and public API test scripts for focused selectors. Read runner context only to resolve an actual validation question.

## Current behavior to preserve

Source PDFs/images/fonts are caller-owned. Supported visible annotations/signatures are retained; source search mappings and advanced PDF semantics retain the existing documented limits. Headless output transfer differs from viewer-owned output cleanup and must be documented precisely.

## Implementation steps

1. Assemble representative local fixtures: PDF with Hebrew label 'מספר דוח', a template-owned number rectangle, visible signature/annotations, a supported static Hebrew TrueType font, PDF/image append sources, and rotated/nonzero-origin pages. Reuse existing fixtures where suitable; new third-party fonts must have redistribution/embedding permission documented.
2. Exercise the exported JS API in the existing example/test harness: openDoc, preload named fonts, resolve label/free bounds, atomic centered one-line value, append/reorder/rotate/remove, repeated finalize, finally-close. Include concurrent independent documents and a mounted-view equivalent.
3. Assert unchanged source hashes, reopened page order/geometry, visible source signature/annotation retention, requested font rendering, logical text extraction, and readable returned outputs after close.
4. Add controlled lifecycle tests for close during admitted loadFonts/import/analysis/export. Already-admitted operations drain; new work rejects; close settles once after worker/artifact/font cleanup. Preserve view replacement/unmount cancellation semantics.
5. Verify source-open counters remain one per normalized font per owner across aliases, many inserts, font size changes, page edits, and multiple exports. Retained page handles must not keep owner font/PDF/analysis resources alive after close. No unused headless undo stacks accumulate.
6. Render representative exported pages and inspect placement/fidelity; verify them in an independent PDF viewer. Record platform/device/API versions and any limitations rather than relying on output-file existence.
7. Update README with both headless examples, loadFonts/view usage, local/bundled URI expectations, static-font limits, errors, null reset, temporary output ownership, and deterministic finally-close.
8. Update maintainer architecture and affected Android/Swift lifecycle/export/text references with shared ownership, queue/thread rules, font resource lifetime, coordinate/atomic-edit rules, headless scope, and validation. Add a headless/font reference and maintainer-skill routing only if needed to keep ownership facts in one place. Write current-state contracts, not implementation history.
9. Mark tasks Completed only for implemented outcomes with accurate evidence. Keep unavailable checks explicitly pending in task records; do not equate generated code or offline builds with runtime validation.

## Ownership and lifecycle rules

Integration tests must keep each owner independent, preserve main-thread state and serial worker access, and await cleanup without blocking the main thread. Keep fixture sources immutable; delete only test-owned copies and outputs after assertions. Returned headless outputs remain caller-owned across close; viewer outputs retain their existing disposal policy. Preserve template bounds and captured coordinate/rotation transforms during visual comparisons.

## Tests and validation commands

- `npm run nitrogen`; `npm run test:public-api`; `npx tsc --noEmit --pretty false`; `npm run build`.
- Android repository runners: `tools\test-android.ps1 -Mode jvm`, `-Mode build`, and focused `-Mode connected -Test <fully-qualified class>`. Cover custom-font export on API24–30 and API31+; report missing API-level runs.
- iOS: compare changed-file SHA-256 hashes with the Mac source, then run `bash ./tools/test-ios-mac-vm.sh` with focused IOS_TEST_ONLY selectors. Use applicable integration build/archive evidence and explicitly report Mac/device unavailability.
- `git diff --check -- ':!nitrogen/generated/**'`.
- Do not run unrelated stroke-engine suites merely because the package contains C++; broaden checks only for changes/failures that justify them.

## Completion criteria

Both platform implementations, public wrappers, font reuse/cleanup, atomic failure behavior, source immutability, visible-content preservation, and post-close output usability have evidence. Documentation matches code/tests and discloses remaining environment checks accurately. No placeholders, hidden views, global font registration/cache, or handwritten generated bindings remain.

Proposed commit: `test: validate and document headless font workflows`
