# Android PDF export

Export uses a snapshot of committed page content from the published working
document. PDF parsing, page-object creation, candidate validation, and
serialization use PDFium on the export worker. Android's PDF renderer is used by
instrumentation tests only as an independent reader and rasterizer.

Original PDF pages and their order are preserved. Committed ink and text are
added as vector PDF content; active gestures and editor state are excluded.
Hebrew and Arabic runs use the bundled Noto Sans Hebrew and Noto Naskh Arabic
fonts, licensed under the SIL Open Font License in `android/src/main/assets/fonts/OFL.txt`.
Text lines keep explicit page coordinates and Unicode mappings in the embedded
font objects.

PDFium reopens the serialized candidate before publication and checks page
metadata, vector-object counts, path geometry, text-object font sizes, and text
placements against the export snapshot. Export does not replace the caller's
source or the working document, and stale or cancelled work cannot publish an
output.
