# iOS rendering

- `PDFView` presents pages and owns native zoom, scrolling, and PDF selection.
- The page overlay provider supplies a transparent PencilKit surface per page.
- Page overlays are temporary. Committed drawings live in page history; live
  strokes and predictions are transient.

- TextKit lays out live editing. Committed rendering and export use the same font
  and paragraph style.
- Text and ink use canonical top-left page coordinates. PDFKit converts between
  page and view coordinates.
