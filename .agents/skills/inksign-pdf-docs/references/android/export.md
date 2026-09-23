# Android PDF export

Export uses a snapshot of committed page content from the published working
document. PDFium work stays on the export worker, and the result is written as a
separate document.

Original PDF pages and their order are preserved. Committed ink and text are
added as vector PDF content; active gestures and editor state are excluded. The
candidate is validated before publication. Export does not replace the caller's
source or the working document, and stale or cancelled work cannot publish an
output.
