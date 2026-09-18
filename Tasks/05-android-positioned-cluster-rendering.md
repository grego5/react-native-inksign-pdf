# 05 — Render positioned replacement clusters on Android

[Back to plan index](../TASKS.md)

Status: Planned

Depends on: [Task 04](04-android-pdfium-geometry-bridge.md)

## Objective

Replace Android's inferred run-level `StaticLayout` compatibility rendering
with system-font shaping of minimal clusters placed by shared PDF geometry.

## Non-goals

- Do not modify source PDFs, export, user-created text, or public APIs.
- Do not repaint complete lines or use paragraph layout for PDF positioning.
- Do not remove the heuristic extractor until cross-platform acceptance.

## Read before editing

- `PdfCompatibilityText.kt`: current masking, preparation, drawing, and diagnostics.
- `PdfSession.kt`: tile and preview rendering order.
- `TextLayout.kt`: reusable typeface/glyph support helpers, not paragraph layout.
- Android viewport and rendering maintainer references.

## Current behavior and invariants

- Compatibility presentation is baked into tiles after source PDF and before ink/user text.
- Previews delegate to the same rendering path.
- Complete-run bidi layout and global horizontal scale are the limitations being replaced.

## Implementation steps

1. Detect replacement records from shared metadata: require valid Unicode,
   visible render mode, a system fallback glyph, and a reason to replace the
   source glyph. Do not overpaint source characters already displayed correctly.
2. Group only adjacent records required for a Unicode shaping cluster, including
   combining marks and scripts that cannot render scalar-by-scalar. Do not
   regroup a complete line or rerun paragraph bidi.
3. Shape each cluster with Android system font APIs at source font size. Apply
   source baseline, matrix, style, and spanned record geometry. Use optional
   displacement only when valid; otherwise rely on origins/bounds.
4. Prepare immutable cluster draw data once per cached page. Cache font/paint
   resolution by style and cull by tile intersection before drawing.
5. Draw through the existing page-to-tile transform in tiles and previews.
   Preserve fill, stroke, and fill-stroke; omit invisible/unsupported modes.
6. Keep bounded debug totals for extracted, replacement, shaped, omitted, and drawn clusters.
7. Use the old provider only when shared extraction is unavailable, never as a second overlay.

## Ownership, performance, and failure rules

- Extraction and shaping are worker-owned and generation-bound.
- No layout, font resolution, or page-sized allocation occurs per frame.
- Malformed clusters are omitted without failing the tile or document.

## Tests and validation

- Add focused non-pixel tests for cluster boundaries, masking, invisible mode,
  transform propagation, and stale prepared data.
- Compare the supplied PDF against Acrobat on a real device for completeness,
  Hebrew direction, mixed ASCII, punctuation, spacing, baselines, zoom, and previews.
- Run Android JVM tests, APK build, connected checks when available, and `git diff --check`.

## Completion criteria

- The supplied PDF is materially comparable to Acrobat without global run stretching.
- Tiles and previews agree across zoom and page changes.
- No pixel-perfect screenshot suite is introduced.

## Proposed commit title

`feat(android): render positioned pdf text clusters`
