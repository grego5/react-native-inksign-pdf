# Android PDF export

## Snapshot and output

- Export snapshots committed page content from the published working document.
  Active gestures and editor drafts are excluded.
- The PDFium worker preserves source pages and their order, adds ink as vector paths
  and text as positioned PDF text objects, then serializes a candidate.
- Reopen the candidate with PDFium and validate page metadata, object counts, path
  geometry, text font sizes, and placements before atomically publishing it.
- Export applies captured page orientation to the output and retains source and
  working bytes. Ink uses raw page-content coordinates; text runs use each
  annotation's layout-to-content transform. See [text geometry](viewport-input.md#text).
- Stale or cancelled work cannot publish output. Replacement and disposal follow the
  [document operation contract](../architecture.md#document-operations).

## Text and fonts

- Store the annotation's base direction and logical Unicode text. Export uses that
  direction for shaping and placement; it does not reverse the source string.
- Resolve logical start/end alignment against direction, then align each PDF
  line inside the fixed physical flow rectangle. Preview and export retain the
  same complete lines.
- Export and preview share complete-line selection within the saved flow region
  and `maxLines`. Vertical anchoring positions the retained block inside that region.
- On API 31+, Android system fallback selects fonts and supplies font resources.
  PDFium's HarfBuzz shapes runs with cluster mappings and explicit positions.
  `ToUnicode` maps glyphs to characters; line-level `/ActualText` records logical
  text for mixed RTL and LTR lines. Embed a selected font only when its
  embedding rights allow it.
- Export embeds selected fonts when permitted and preserves glyph rendering and
  text extraction when subsetting is used. It saves full font programs when font
  rights or glyph mappings require them, and retries with full fonts if subset
  serialization fails. Font collections currently use the first face.
- On API 24–30, selected Android font bytes are unavailable; use PDFium's standard-font
  fallback as a best-effort path. Missing glyph coverage or embedding rights alone do
  not reject finalize; affected glyphs may be blank or partial.

## Verification

- Required export checks cover reopened metadata, rendered ink/text placement,
  and independent logical-text extraction. Font checks compare subset and full-font
  output for extraction, glyph positions, and font-resource reuse.

Direction selection and editing behavior are described in
[viewport-input.md](viewport-input.md).
