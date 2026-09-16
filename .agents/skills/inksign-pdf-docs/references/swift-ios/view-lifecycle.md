# iOS view and document lifecycle

## Ownership

- `PdfView` owns PDFKit presentation, PencilKit input, page history, and export
  orchestration.
- `InkSignPdfDocumentState` owns the source document, ordered pages, active page,
  generation, and committed page content.
- The text overlay owns the temporary editor, selection, dragging, and keyboard
  behavior. The page-turn lifecycle owns preview and handoff presentation.
- JavaScript owns props, commands, and coarse callbacks only; native owns PDF,
  PencilKit, gesture, and history state.

## Loading and readiness

- The retained page-overlay provider supplies the active page's compatibility
  text view and transparent `PKCanvasView`. PDFKit may detach and reattach it
  during layout without changing history.
- `open()` advances the document generation, cancels current work, and loads a
  validated local PDF. Invalid or empty documents and invalid page geometry are
  rejected.
- The open operation resolves only after the active overlay and page transform
  are ready. Superseded or disposed loads cannot install their result.
- Caller-owned source files are read-only. Native cleanup is limited to exact
  module-created cache artifacts.

## Navigation and disposal

- Page switches install only the target page's committed content and complete
  after its overlay and transform are ready. Preview and handoff results carry
  generation/identity checks so stale work cannot replace current presentation.
- Disposal is UI-thread-owned and idempotent. It cancels input, navigation,
  previews, and export, removes the overlay, releases the document, and clears
  callbacks. Late worker results cannot mutate the view.

