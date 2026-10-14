# 06 - Prepare CoreText export resources

[Plan](../TASKS.md)

Status: Complete (iOS implementation and applicable simulator checks)
Complexity: High
Depends on: 05

## Objective and non-goals

Prepare owned fonts and positioned glyphs from committed CoreText layout for the
common writer. Preserve UIKit editing, font selection, and complete-line policy;
do not reshape iOS lines with HarfBuzz.

## Read before editing

- `ios/TextRendering.swift`: `makeLineFragments`, complete-line selection,
  `drawCanonical`, text attributes, and layout transforms.
- `ios/PDFVectorAnnotation.swift`: current appearance drawing.
- `ios/InkSignView+Export.swift`: immutable snapshots.
- Task 05's common model; `core/pdfium-adapter/PdfiumFontCoverage.*`:
  supported font normalization.
- Maintainer `swift-ios/export.md`; apply the Swift/C++ implementation skills
  appropriate to the boundary being edited.

## Current contract

CoreText resolves and shapes system/fallback fonts. Preview/export select the same
complete lines using hard flow bounds, maxLines, alignment, direction, and anchor.
Text retains its captured layout after page rotation.

## Implementation

1. Expose an immutable snapshot from the existing line-fragment path: full logical
   line text, CTLine/CTRun glyph data, positions, baselines, colors, saved
   layout-to-canonical transform, and flow clipping. Share line selection rather
   than copying its formulas into a second layout implementation.
2. Use CTRun glyph IDs, positions, string indices, and actual CTFont attributes.
   Derive source clusters with explicit RTL/non-monotone ordering, preserving
   ligatures, combining sequences, and surrogate pairs. Map each cluster's
   logical text once and preserve the full logical line for ActualText.
3. Add an export-owned font cache. Read exact face bytes from readable font URLs
   or reconstruct an SFNT face from CoreText/CGFont tables where no readable URL
   exists. Reuse existing normalization where applicable. Deduplicate within the
   export rather than retaining a global per-viewer font registry.
4. Preserve variation instances and glyph-ID correspondence. Actual Apple font
   embeddability is a required runtime gate, not an established fact. If the
   common path cannot embed the exact face, fail with a specific export error
   identifying the face/format. Do not silently substitute Helvetica, rasterize
   text, or publish incorrect glyphs. A different font policy requires review.
5. Bridge owned bytes/glyphs to the common model. Specify index units, baseline
   signs, and affine transforms. No borrowed buffer or CoreText object outlives
   preparation; the output model owns what native writing needs.
   Keep hard-bounded text clipping local to the inserted content. PDFium's public
   clip insertion affects a whole page, not one text object. For bounded content,
   use a transparent temporary page with the captured clip, then insert a Form
   XObject at the source media-box origin. Never clip the source page globally.
   Common validation must traverse form children and compose parent transforms;
   verify PDFKit rendering/extraction at Task 08 before accepting this path.
6. Keep shaping/resource preparation callable without a view. Task 10 adds
   owner-local named-font selection to this same path; do not tie font resources
   or text defaults to an overlay, selected page, or PDFView.

## Static validation and completion

- Preview and export share selected lines and captured wrapping without a second
  shaping pass. Existing hard bounds and alignment remain authoritative.
- Font feasibility failures are distinguishable from write/reopen failures;
  focused runtime embedding/export checks passed.
- Run `git diff --check`.
- Proposed commit: `feat(ios): prepare CoreText glyphs and fonts for PDFium export`.

## Implementation progress

- Committed drawing and resource preparation share `positionedLines`, including
  selected complete lines, alignment, baseline, captured transform, and clip.
- Export-local snapshots own glyph IDs, UTF-16 clusters, positions, colors, and
  reconstructed TrueType resources. Cluster text maps once despite repeated
  glyph indices or RTL order. Unsupported variable/transformed faces fail.
- Native values bridge owned resources to the common writer. Local Form XObject
  clipping and recursive composed-transform validation are connected to export.
- Authored whitespace check passed. Compilation and runtime checks remain
  covered by focused CoreText export checks; supported font policy remains explicit.
