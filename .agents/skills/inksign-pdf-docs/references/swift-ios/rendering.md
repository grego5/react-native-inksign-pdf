# iOS rendering

PDFium supplies the base page imagery. A transparent native overlay presents
committed and in-progress PencilKit content; predictions remain temporary until
the drawing is committed to page history.

Page-turn previews combine the target PDF page with its committed annotations. A
rendered result is installed only while its document and page request remain
current. Text annotations use canonical top-left page coordinates. Their
intrinsic content size is retained, while drawing is clipped to the page bounds.
