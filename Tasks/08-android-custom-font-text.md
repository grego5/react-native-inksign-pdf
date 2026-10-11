# 08 — Carry Android custom fonts through text and export

[Plan index](../TASKS.md)

Status: Planned
Complexity: High
Dependencies: 06

## Objective and non-goals

Make every text entry path use the selected loaded font consistently for layout, editing, and PDF embedding on all supported Android versions. Do not expand font formats or alter default system-font behavior.

## Read before editing

- Shared DocumentTextCommands/NamedFontRegistry and generated option/value setter signatures.
- `InkHistory.kt`: TextAnnotation and immutable content; `TextLayout.kt`: createPaint, measureWrapped, createLayout, fitsFlow, fitsMaxLines, visibleBounds, configureEditor.
- `TextInteractionOverlay.kt`: placement, draft options/value, editor reopening and reflow.
- `PdfExport.kt`: PdfExportTextResolver, Api31FontResolver, resource deduplication and pre-31 branch.
- `PdfiumNativePdfExporter.kt` and `android/src/main/cpp/pdfium_export_jni.cpp`: resource transport, HarfBuzz shaping, CID font embedding, fallback behavior.
- Maintainer Android export/viewport-input references; Kotlin, C++, and native-module implementation skills.

## Current behavior to preserve

Font measurement defaults to Typeface.DEFAULT; export selects system resources on API31+ and uses standard-font fallback below that. Existing system-font fallback behavior remains for annotations without an explicit custom font. Bounded layout retains complete lines and captured transforms.

## Implementation steps

1. Save selected font identity and immutable resolved resource in target/draft/annotation state. Omitted font retains current selection; null resets to system; explicit names resolve before any mutation. Resource equality participates in annotation/style comparisons.
2. Route the resource's Typeface through all measurement/layout/editor calls, including wrapping, visible-line selection, empty editor sizing, font-size adjustment, reopen, and committed preview. Keep fontSize independent of resource identity.
3. Complete atomic setTextValue/setValue(options): merge supplied options against current draft/annotation formatting, validate font selection and compute layout first, then publish. Target options supply defaults only when there is no current content. A font-only change with unchanged text still reflows; empty text removes module content while preserving current formatting/source fallback. Missing glyphs permit rendering fallback rather than rejecting input.
4. Resolve interactive TextModeOptions.font before changing mode/draft state. Reject unknown names without partially entering placement. Use shared resources for selected-text handles and programmatic/headless insertion.
5. Supply cached custom bytes directly to PDFium/HarfBuzz on all supported API levels. On API31+, reuse Android's selected system fallback resources for missing glyphs. Preserve logical Unicode, bidi segmentation, alignment, line selection, ToUnicode/ActualText, and layout-to-canonical mapping.
6. Deduplicate custom font resources across pages/annotations per export; capture references instead of reopening source URIs. Preserve existing full/subset serialization policy and embedding checks.
7. Distinguish explicit custom resources in JNI/native shaping so named-font shaping/embedding failure cannot silently use Helvetica. Missing glyphs permit rendering fallback; below API31, custom export uses the font's missing-glyph appearance. Export failures reject finalize and clean unpublished output. Implicit system resources retain the established best-effort fallback behavior.
8. Finish all Android generated signatures and registry methods so the platform builds without placeholders.

## Ownership, threading, and geometry

Sync edits use cached native resources only. Worker export snapshots retain resources until completion/cleanup; close waits for them. Font changes preserve the template flow rectangle, stable target ID, writing rule/source association, and captured orientation. Center aligns within the designated rectangle, independent of whole-page width.

## Tests and expected results

Extend text placement/key and export instrumentation tests with bundled Hebrew-capable font, numbers, mixed RTL/LTR, maxLines=1, rotations, and nonzero media origins. Assert atomic failure leaves metadata/draft/content unchanged and successful viewer value/options changes undo once. Compare preview/export bounds and extracted logical text. Exercise API24–30 and API31+ custom-resource branches; repeated insertions/finalize never reread source, and aliases embed once per export.

## Validation and completion

Run Android JVM tests, build, and focused TextPlacementInstrumentationTest, HybridInkSignViewTextKeyTest, PdfExportContourTest, registry and headless tests. Use repository runners and correct device ABI. A modern-device run alone does not verify the pre-31 path; report missing device coverage. Complete when custom fonts work end to end and the Android native target compiles.

Proposed commit: `feat(android): use named fonts for text layout and PDF export`
