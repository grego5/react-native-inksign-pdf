# Android PDF export

## Snapshot and output

- `finalize()` returns the published output as a `file://` URI; artifact
  ownership and cleanup retain filesystem paths. Output remains view-owned.
- Export snapshots committed page content from the published working document.
  Active gestures and editor drafts are excluded.
- The PDFium worker preserves source pages and their order, adds ink as vector paths
  and text as positioned PDF text objects, then serializes a candidate.
- Reopen the candidate with PDFium and validate page metadata, object counts, path
  geometry, text font sizes, and placements before atomically publishing it.
- Export retains source and working bytes. Text shaping and line selection use
  saved local layout; positioned runs carry the annotation's layout-to-canonical
  transform. The PDFium adapter converts canonical content to PDF coordinates,
  including the media-box origin, and persists captured page orientation once
  as page metadata. Ink keeps its canonical content mapping. See
  [text geometry](viewport-input.md#text).
- Stale or cancelled work cannot publish output. Replacement and disposal follow the
  [document operation contract](../architecture.md#document-operations).

## Text and fonts

- Store the annotation's base direction and logical Unicode text. Export uses that
  direction for shaping and placement; it does not reverse the source string.
- Resolve logical start/end alignment against direction within the saved flow
  region. Preview/export share complete-line selection under flow/maxLines limits;
  vertical anchoring positions the retained block.
- Named fonts supply cached TrueType bytes on every supported Android version.
  JNI records whether each resource is an explicit selection: named-font shaping
  and embedding failures reject export; implicit system resources retain the
  existing best-effort fallback. Missing glyphs are rendering outcomes, not input errors.
- On API 31+, Android system fallback selects fonts and supplies font resources,
  including text entered with a named font. Reuse owner-cached bytes when Android
  selects the named face; embed the selected system resource for fallback runs.
  Preserve resolved font selections for digits, punctuation, and combining marks;
  weak characters without a usable selection may inherit a neighboring run font.
  PDFium's HarfBuzz shapes runs with cluster mappings and explicit positions.
  `ToUnicode` maps glyphs to characters; line-level `/ActualText` records logical
  text for mixed RTL and LTR lines. Embed a selected font only when its
  embedding rights allow it.
- Export embeds selected fonts when permitted and preserves glyph rendering and
  text extraction when subsetting is used. It saves full font programs when font
  rights or glyph mappings require them, and retries with full fonts if subset
  serialization fails. Font collections currently use the first face.
- On API 24–30, selected system font bytes are unavailable; system-only text uses
  PDFium's standard-font fallback. Named fonts remain embedded; unsupported glyphs
  use their missing-glyph appearance, which can differ from Android preview. Missing glyph coverage or embedding rights alone do
  not reject finalize; affected glyphs may be blank or partial.

## Verification

- Required export checks cover reopened metadata, rendered ink/text placement,
  and independent logical-text extraction. Font checks compare subset and full-font
  output for extraction, glyph positions, and font-resource reuse.

Direction selection and editing behavior are described in
[viewport-input.md](viewport-input.md).
