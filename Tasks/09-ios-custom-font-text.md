# 09 — Carry iOS custom fonts through text and export

[Plan index](../TASKS.md)

Status: Planned
Complexity: High
Dependencies: 07

## Objective and non-goals

Use preloaded named fonts consistently in iOS UI/headless text creation, editing, measurement, and exported appearances. Do not broaden font formats or alter default system-font behavior.

## Read before editing

- Shared DocumentTextCommands/NamedFontRegistry and generated value/options signatures.
- `ios/DocumentState.swift`: target option conversion; `TextState.swift`: InkSignPdfTextAnnotation reflow and history snapshots.
- `ios/TextRendering.swift`: InkSignPdfTextStyle.font/attributes, complete-line layout and renderer.
- `ios/TextInteraction.swift`, `TextEditorLayout.swift`, and `TextCommands.swift`: placement, draft state, programmatic/handle operations.
- `ios/NativePDFExporter.swift` and shared export snapshots: CoreText appearance generation and annotation bounds.
- Maintainer Swift export/viewport-input references; Swift/native-module implementation skills.

## Current behavior to preserve

CoreText/UIKit currently derive a system font from fontSize. Text retains logical Unicode, direction, local layout, and captured orientation. Export uses locked, selectable module text annotations and fixed flow bounds.

## Implementation steps

1. Carry immutable resolved font resources and named selection through target options, drafts, annotations, cloning/reflow, and history equality. Omission preserves current selection; null restores system; explicit names resolve before mutation.
2. Extend InkSignPdfTextStyle and all measurement/rendering/editor call sites to accept the selected resource. Use the same underlying face for UIFont editor configuration and CoreText preview/export. Eliminate custom-font paths that still derive line height or fitting from systemFont.
3. Complete atomic value/options setters and TextHandle equivalents. Merge/validate font selection and shaped glyph coverage, compute reflow, then publish one draft/content change. Unchanged text with a new font still changes layout; empty text preserves target formatting and source fallback while removing module text.
4. Resolve TextModeOptions.font before replacing interactive mode/draft state. Preserve programmatic, selected-text, and nonactive-page behavior through the shared text service.
5. Pass retained resources through detached export snapshots and CoreText appearance generation. Preserve logical text, font embedding/appearance fidelity, complete-line limits, bounds, canonical mapping, and locks. Do not read the original font URI during export.
6. Reject missing drawable glyphs before editing; do not treat bidi/control characters as missing printable glyphs. Explicit custom text must not silently select a fallback face. Failed layout/export must leave working content intact and remove unpublished output.
7. Retain resources during workers, and release them through existing owner teardown after completion. Finish the platform's generated interface implementations without placeholders.

## Ownership, threading, and geometry

State/editor work stays on the main thread; export uses immutable native snapshots on pdfQueue. No global font registration. Keep stable target IDs, field source associations, flow rectangles, rotation, media-box origins, and coordinate contracts intact. Center within template bounds, never an inferred page-wide rectangle.

## Tests and expected results

Extend InkSignViewTextInteractionTests and SignatureExportTests with the same bundled font used on Android. Cover Hebrew labels/numbers, mixed-direction text, wrapping/one-line clipping, font-size changes, null reset, rotations, nonactive pages, and empty-value fallback. Failed options/glyph edits leave all state unchanged; one successful viewer transaction undoes once. Verify headless/viewer exports render the requested font and retain source visible annotations/signatures. Count source reads across repeated edits/exports.

## Validation and completion

On the verified Mac source, run focused text, signature/export, registry, and headless test classes with the repository runner, then an applicable integration build. Inspect exported fixture rendering and extraction, including an external PDF viewer. Report unavailable visual/device checks separately. Complete when the iOS native target compiles and all custom-font entry paths use the cached face.

Proposed commit: `feat(ios): use named fonts for text layout and PDF export`
