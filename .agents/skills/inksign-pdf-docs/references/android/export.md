# Android PDF export

## Snapshot and output

- Export snapshots committed page content from the published working document.
  Active gestures and editor drafts are excluded.
- The PDFium worker preserves source pages and their order, adds ink as vector paths
  and text as positioned PDF text objects, then serializes a candidate.
- Reopen the candidate with PDFium and validate page metadata, object counts, path
  geometry, text font sizes, and placements before atomically publishing it.
- Export leaves the caller's source and working document unchanged. Stale or cancelled
  work cannot publish an output.

## Text and fonts

- Store the annotation's base direction and logical Unicode text. Export uses that
  direction for shaping and placement; it does not reverse the source string.
- On API 31+, Android system fallback selects fonts and supplies font resources.
  PDFium's HarfBuzz shapes runs with cluster mappings and explicit positions.
  `ToUnicode` maps glyphs to characters; line-level `/ActualText` preserves logical
  extraction order for mixed RTL and LTR text. Embed a selected font only when its
  embedding rights allow it.
- On API 24–30, selected Android font bytes are unavailable; use PDFium's standard-font
  fallback as a best-effort path. Missing glyph coverage or embedding rights alone do
  not reject finalize; affected glyphs may be blank or partial.

## Verification

- Android instrumentation checks PDFium rendering and metadata plus independent logical-text
  extraction with PDFBox.

Direction selection and editing behavior are described in
[viewport-input.md](viewport-input.md).
