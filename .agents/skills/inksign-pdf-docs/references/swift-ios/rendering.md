# iOS rendering

PDFKit and Quartz supply the base page imagery. A transparent native overlay presents
committed and in-progress PencilKit content; predictions remain temporary until
the drawing is committed to page history.

Page-turn previews combine the target PDF page with its committed annotations.
CoreText shapes committed text. A rendered result is installed only while its
document and page request remain current. Text and ink use canonical top-left
page coordinates independent of viewport zoom and display scale.
