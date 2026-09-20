# iOS view and document lifecycle

## Ownership

- `InkSignView` owns the PDFium page host, PencilKit input, page history, and export
  orchestration. Its document state retains the Objective-C++ PDFium session
  façade and the source PDFKit document needed by export/metadata paths.
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
  not change history.
- `open()` advances the document generation, cancels current work, and loads a
  validated local PDF. The same source bytes open a PDFium session on its
  serial worker; invalid fallback-font resources, empty documents, page-count
  mismatches, and invalid page geometry are rejected. Invalid fallback-font
  configuration reports `invalid_fallback_font` with the native reason.
- PDFium supplies page dimensions and all base display pixels. The retained
  PDFKit document remains available only for source metadata and export
  requirements.
- The open operation resolves only after the active overlay and page transform
  are ready. Superseded or disposed loads cannot install their result.
- Caller-owned source files are read-only. Native cleanup is limited to exact
  module-created cache artifacts.

## Navigation and disposal

- Page switches install only the target page's committed content and complete
  after its overlay and transform are ready. A committed page-turn handoff enters
  its waiting state before overlay readiness can be reported. Readiness dismisses
  its preview only for the matching switch ID. Preview and handoff results carry
  generation/identity checks so stale work cannot replace current presentation.
- Disposal is UI-thread-owned and idempotent. It cancels input, navigation,
  previews, and export, removes the overlay, releases the document, and clears
  callbacks. Late worker results cannot mutate the view.
