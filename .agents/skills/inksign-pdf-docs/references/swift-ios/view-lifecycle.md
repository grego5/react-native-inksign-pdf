# iOS view and document lifecycle

## Ownership

- `InkSignView` adapts Nitro commands and UIKit presentation. The document
  coordinator owns the published PDFKit document, PDFium session, generation,
  ordered page collection, active page identity, page histories, and exact
  working and output artifacts.
- The coordinator admits one open, finalize, or structural operation at a time.
  Structural admission is the boundary for future picker staging and page
  commands. A replacement open keeps the prior published document until the
  new document reaches open readiness; failed or canceled replacement restores
  the prior document.
- `InkSignView` owns the page-input coordinator. The coordinator owns one
  main-thread picker request and stages Files, Photo Library, and caller-provided
  local sources into exact module cache artifacts before a structural mutation
  consumes them.
- `InkSignView` owns viewport commands and lifecycle completion. Open readiness
  covers the document, first page, overlay, bounds, geometry, and requested fit
  scale before the target is applied and the promise is published.
- `InkPdfView` is a leaf presentation component. It owns the current canonical
  focus, zoom, page frame, immutable `PageViewportTransform`, and PDFium tiles.
- Each page has a stable native identity; its current index comes from its
  position in the coordinator's ordered collection. The active page is stored
  by identity. The Objective-C++ facade owns the native PDFium session and
  serializes all PDFium operations.
- The text overlay owns the temporary editor, selection, dragging, and keyboard
  behavior. The page-turn lifecycle owns preview and handoff presentation.
- JavaScript owns props, commands, and coarse callbacks only; native owns PDF,
  PencilKit, gesture, and history state.

## Loading and readiness

- The retained page-overlay provider supplies the transparent `PKCanvasView`
  above the active PDFium tile host. Tile replacement and layout changes do
  operate on presentation state; history stores committed page content.
- `open()` copies a validated local PDF into an exact module-owned working
  artifact, then loads that artifact and creates its PDFium session on a serial
  worker. Invalid fallback-font resources, empty documents, page-count
  mismatches, and invalid page geometry are rejected. Invalid fallback-font
  configuration reports `invalid_fallback_font` with the native reason.
- PDFium supplies page dimensions and all base display pixels. The retained
  PDFKit document remains available only for source metadata and export
  requirements.
- The open operation publishes page info after the active overlay and page
  transform are ready.
- Caller-owned source files are read-only. The coordinator releases the
  working artifact on replacement or disposal. Native cleanup is limited to
  exact module-created cache artifacts.
- Files security-scoped access is balanced around each copy. Photo provider
  temporary URLs are copied during the provider completion callback. Photo
  multi-selection uses ordered mode and the picker is dismissed before staging;
  worker state retains only ordered staged URLs and resolved `pdf`/`image` types.

## Navigation and disposal

- Page switches install target-page committed content. Preview and handoff
  results carry generation and page identity checks.
- Finalize captures page history and an immutable source-artifact path before
  worker processing. The worker publishes only while its coordinator operation
  and document generation remain current; disposal removes pending and owned
  artifacts and invalidates publication.
- Disposal is UI-thread-owned and idempotent. It cancels input, navigation,
  previews, and export, removes the overlay, releases the document, and clears
  callbacks. It also cancels picker staging and removes its partial cache
  artifacts. Worker results use generation checks.
