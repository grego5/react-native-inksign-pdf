# iOS rendering

- `PDFView` renders source pages and provides scrolling, paging, zoom, coordinate
  conversion, and overlay hosts. `ViewerViewportController` owns programmatic
  viewport motion and keyboard adjustments.
- Page overlays present committed core content and transient PencilKit input.
  Overlay lifetime is independent of content/history; presentation leases retain
  the working PDF while PDFKit uses it.
- TextKit lays out live editing; `InkSignPdfTextRenderer`/CoreText select committed lines
  shared with export. Captured layout → canonical → display mapping preserves
  annotation wrapping/orientation.
- Input routing: [viewport/input](viewport-input.md). Snapshot/lease ownership:
  [lifecycle](view-lifecycle.md). PDF content writing: [export](export.md).
