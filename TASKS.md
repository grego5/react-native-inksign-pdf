# iOS PDF and annotation stabilization

Stabilize iOS PDF rendering, viewport interaction, ink presentation, and text
annotations by correcting the owning abstractions rather than layering narrow
guards over inconsistent state. Android is the behavioral reference: view mode
owns pan, pinch, double-tap, and navigation; edit mode owns drawing; committed
content remains in canonical page space.

## Constraints

- Use media-box-relative page coordinates with a top-left origin for stored
  ink and text.
- Keep zoom clamped to `0.1...16` and keep PDF work off the main thread.
- Do not edit `nitrogen/generated/**` or add a high-frequency JavaScript path.
- Prefer one streamlined ownership and data-flow model over compatibility
  shims, duplicated transforms, fallback branches, or defensive checks that
  allow invalid state to continue.
- Breaking internal or public changes are acceptable when required for a
  coherent design. Document any public break and its replacement explicitly;
  do not introduce a break when the existing contract already supports the
  correct architecture.
- Existing documentation and tests are discovery evidence, not constraints on
  the corrected design. Rewrite or remove assertions that preserve incorrect
  ownership, geometry, lifecycle, or interoperability behavior; do not add
  adapters solely to keep obsolete tests passing.
- Tasks 1 through 4 are architectural slices, not release checkpoints. A task
  may leave transitive callers, compilation, or tests temporarily broken when
  a later listed task completes the migration. Disclose the expected breakage
  in the task handoff instead of building temporary adapters.
- Add or update focused tests alongside the owning change, but defer full test
  execution, Xcode builds, simulator/device checks, and integrated validation
  until Task 5. Do not repeat unavailable macOS validation after every task.
- The local Windows environment is for static correctness only: inspect types,
  ownership, call graphs, state transitions, arithmetic, diffs, and generated-
  file boundaries. Do not attempt to infer iOS build or runtime success here.
- These briefs target a low-effort implementation model. Follow the stated
  ownership, data flow, constants, and migration order directly. Do not invent
  alternate architectures, optional compatibility modes, or extra scope.
- Report macOS/Xcode, simulator, and device validation as unavailable when it
  cannot actually be run.

## Task order

1. [Unify the iOS page transform](Tasks/01-unify-ios-page-transform.md)
2. [Bound PDFium tile rendering](Tasks/02-bound-pdfium-tile-rendering.md)
3. [Correct mode and ink routing](Tasks/03-correct-mode-and-ink-routing.md)
4. [Rebuild text editor layout](Tasks/04-rebuild-text-editor-layout.md)
5. [Integrate and validate iOS stability](Tasks/05-integrate-and-validate-ios-stability.md)

Tasks 2 through 4 consume Task 1's intended model and may complete its caller
migration. Task 5 restores and validates the integrated build after Tasks 1
through 4.

Run macOS compilation and tests once, at the end of Task 5, through one manual
GitHub Actions validation run. Do not spend runner time on intermediate tasks.
Use one reusable workflow with a required focus switch rather than duplicating
macOS setup across multiple workflow files. For this change, run only the new
stabilization regression suite; stable lifecycle and PDFium smoke coverage stay
available as explicit opt-in focuses. Exclude archive/signing, Android, C++,
TypeScript, and physical-device work from this workflow.
