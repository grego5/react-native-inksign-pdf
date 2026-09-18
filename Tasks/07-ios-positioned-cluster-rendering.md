# 07 — Render positioned replacement clusters on iOS

[Back to plan index](../TASKS.md)

Status: Planned

Depends on: [Task 06](06-ios-pdfium-geometry-bridge.md)

## Objective

Render fallback glyph clusters through Core Text/Core Graphics using shared PDF
character geometry, replacing PDFKit run reconstruction as the primary iOS path.

## Non-goals

- Do not alter PDFKit, PencilKit, user text, history, export, or public APIs.
- Do not use paragraph layout to recompute line order or spacing.
- Do not remove fallback code before device acceptance.

## Read before editing

- `ios/CompatibilityText.swift`: glyph support, current drawing, and view ownership.
- `ios/PagePreview.swift`: preview transform and draw order.
- `ios/PdfView+Overlay.swift` and `ios/PageOverlay.swift`: live overlay installation.
- iOS viewport and rendering maintainer references.

## Current behavior and invariants

- Compatibility text draws below PencilKit and stays outside export/history.
- Live overlays and previews consume immutable page-local presentation data.
- Current runs are reconstructed from attributed strings and unioned bounds.

## Implementation steps

1. Apply the same replacement and clustering contract as Android. Platform font
   choice may differ, but eligibility, invisible-mode rejection, and geometry boundaries agree.
2. Shape minimal clusters with `CTFont`/Core Text without paragraph line layout.
   Resolve fallback fonts per cluster and omit LastResort/missing glyphs.
3. Draw with source baseline, transform, fill/stroke style, and geometry spanned
   by PDF records. Respect displacement only when extractor marked it valid.
4. Prepare immutable page presentation once per cache entry and reuse it for
   live overlays and previews; do not reshape during drawing or animation.
5. Preserve existing canonical overlay/preview transforms and draw order.
6. Use PDFKit fallback only when shared extraction fails, never additively.
7. Add bounded code-point diagnostics matching Android categories.

## Ownership, performance, and failure rules

- Prepared Core Text values are invalidated with their generation/cache entry.
- Missing or malformed clusters are omitted without blocking PDF display.
- Per-frame work is culling, transform application, and prepared-glyph drawing.

## Tests and validation

- Add focused non-pixel tests for eligibility, cluster boundaries, font fallback,
  transform propagation, and lifecycle invalidation.
- Compare the supplied PDF with Acrobat on a real iOS device for completeness,
  RTL order, mixed ASCII, spacing, baseline, zoom, and previews.
- Run iOS lifecycle tests and `git diff --check`; report pending device validation.

## Completion criteria

- iOS uses shared geometry for its primary compatibility overlay.
- Live pages and previews agree without paragraph relayout.
- No pixel screenshot tests are added.

## Proposed commit title

`feat(ios): render positioned pdf text clusters`
