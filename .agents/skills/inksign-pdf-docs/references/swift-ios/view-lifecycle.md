# iOS view and document lifecycle

## Ownership

- `InkSignView` owns the PDFium page host, PencilKit input, page history, and export
  orchestration. Its document state retains the Objective-C++ PDFium session
  façade and the source PDFKit document needed by export/metadata paths.
- `InkSignView` owns viewport commands and lifecycle completion. Open readiness
  covers the document, first page, overlay, bounds, geometry, and requested fit
  scale before the target is applied and the promise is published.
- `InkPdfView` is a leaf presentation component. It owns the current canonical
  focus, zoom, page frame, and PDFium tiles.
- `InkSignPdfDocumentState` owns the source document, ordered pages, active page,
  PDFium page session, generation, and committed page content. The façade keeps
  its native session and serial worker private to Objective-C++.
- The text overlay owns the temporary editor, selection, dragging, and keyboard
  behavior. The page-turn lifecycle owns preview and handoff presentation.
- JavaScript owns props, commands, and coarse callbacks only; native owns PDF,
  PencilKit, gesture, and history state.

## Loading and readiness

- The retained page-overlay provider supplies the transparent `PKCanvasView`
  above the active PDFium tile host. Tile replacement and layout changes do
  operate on presentation state; history stores committed page content.
- `open()` loads a validated local PDF and creates its PDFium session on a
  serial worker. Invalid fallback-font resources, empty documents, page-count
  mismatches, and invalid page geometry are rejected. Invalid fallback-font
  configuration reports `invalid_fallback_font` with the native reason.
- PDFium supplies page dimensions and all base display pixels. The retained
  PDFKit document remains available only for source metadata and export
  requirements.
- The open operation publishes page info after the active overlay and page
  transform are ready.
- Caller-owned source files are read-only. Native cleanup is limited to exact
  module-created cache artifacts.

## Navigation and disposal

- Page switches install target-page committed content. Preview and handoff
  results carry generation and page identity checks.
- Disposal is UI-thread-owned and idempotent. It cancels input, navigation,
  previews, and export, removes the overlay, releases the document, and clears
  callbacks. Worker results use generation checks.
