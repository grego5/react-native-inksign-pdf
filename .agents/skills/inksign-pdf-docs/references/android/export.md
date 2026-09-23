# Android PDF export

Export uses a snapshot of committed page content from the published working
document. PDF parsing, page-object creation, candidate validation, and
serialization use PDFium on the export worker. Instrumentation uses PDFium for
raster and page metadata checks and PDFBox for independent logical-text extraction.

Original PDF pages and their order are preserved. Committed ink and text are
added as vector PDF content; active gestures and editor state are excluded.
Android chooses annotation fonts from system fallback. On API 31 and newer the
export snapshot includes selected font data; PDFium's HarfBuzz shapes each run
and supplies glyph-cluster mappings, explicit positions, and embedded font
objects when the font's embedding permissions allow it. A line-level
`ActualText` mapping keeps extraction in logical Unicode order for mixed RTL and
LTR text. Text direction is fixed when the annotation is placed and stored with
the annotation; the React app selects it with the view ref method.

Android does not expose selected font bytes on API 24–30. Those releases use
PDFium's standard-font fallback as a best-effort path. Missing glyph coverage or
embedding permission alone does not reject finalize; affected glyphs may be
blank or partial.

PDFium reopens the serialized candidate before publication and checks page
metadata, vector-object counts, path geometry, text-object font sizes, and text
placements against the export snapshot. Export does not replace the caller's
source or the working document, and stale or cancelled work cannot publish an
output.
