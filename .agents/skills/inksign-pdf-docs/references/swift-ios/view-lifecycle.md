# iOS view and document lifecycle

## Ownership

- `InkSignView` adapts Nitro commands and UIKit presentation. The document
  coordinator owns the published PDFKit document, PDFium session, generation,
  ordered page collection, active page identity, page histories, and exact
  working and output artifacts.
- The coordinator admits one open, finalize, or structural operation at a time.
  Structural admission is the boundary for future picker staging and page
  commands. A new open cancels a pending open before admission; other conflicting
  operations reject. A replacement open keeps the prior published document until
  the new document reaches open readiness; failed or canceled replacement restores
  the prior document, viewport, and editing mode.
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
  position in the coordinator's ordered collection. The coordinator selects the
  active page by identity. The Objective-C++ facade owns the native PDFium session and
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
  worker. Structural mutation builds its candidate in the document coordinator
  and validates PDFKit and PDFium reopening, page counts, page sizes, and geometry.
  Invalid fallback-font resources, empty documents, page-count
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

## Mutable pages

- `addPages`, `removePage`, and `movePage` use the coordinator's structural
  operation admission. Rejected commands, same-index moves, and canceled page
  selection leave active text editing unchanged. Text editing is committed when
  a valid structural mutation begins; an active ink gesture rejects the command.
- Selected files and provider results are staged into module-owned artifacts.
  Image inputs are orientation-corrected and encoded as page-sized JPEG data
  with white background, contain fit, a 200 DPI cap, and 0.72 JPEG quality.
  Selected PDFs contribute their pages in selection order.
- With an open document, PDFium assembles a detached candidate from the current
  working PDF. Without one, `addPages` creates a PDF directly from the staged
  inputs; image pages use letter-size geometry. The candidate must reopen in
  both PDFKit and PDFium and have matching page counts before the coordinator
  publishes its file, sessions, page records, active page identity, generation,
  and structural dirty state together.
- Existing page IDs and page histories follow their pages through append,
  removal, and movement. Append activates its first new page; removal selects
  the next page at the removed index or the preceding page when removing the
  last page; movement keeps the moved page active. Structural changes remain
  dirty independently of per-page undo and redo history.
- Failed or stale candidates are closed and deleted without changing the
  published document. Replacing open and disposal invalidate structural work
  and clean its staged and candidate artifacts.

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
