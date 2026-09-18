# View and document lifecycle

## Ownership

- PdfView is the Fabric-mounted Swift UIView boundary. It owns PDFKit
  presentation, PencilKit presentation/input, page history, and export
  orchestration.
- InkSignPdfDocumentState owns the source document, ordered page states, active
  page, and document generation. Each page owns canonical committed ink/text
  history and its content revision.
- InkSignPdfTextInteractionOverlay owns transient text selection, editing,
  dragging, the single UITextView, keyboard avoidance, and placement. It routes
  outside-editor movement through the shared PDF viewport.
- InkSignPdfPageTurnLifecycle owns main-thread preview preparation,
  presentation, settlement, and retained handoff snapshots.
- JavaScript owns only the host view, props, commands, and coarse callbacks. It
  never owns PDF objects, PencilKit drawings, recognizers, or point arrays.

## View hierarchy and readiness

- PDFView is the clipped document/navigation container. A retained page-overlay
  provider supplies one transparent container for the active page; the
  container layers a noninteractive compatibility-text view below the stable
  PKCanvasView. The provider is retained because
  PDFView.pageOverlayViewProvider is weak.
- Install the provider before the document. It returns the retained container
  only for the active page, and PDFKit may detach/re-attach it during layout
  without changing committed history. `PdfView.canvasView` remains the stable
  PencilKit accessor; text editing remains a child of that canvas.
- willDisplayOverlayView records the attached PDFPage. Transform refresh,
  drawing installation, and page-switch completion require that page to equal
  the active page; stale detaches cannot clear a newer attachment.
- The cache policy resolves and creates the configured cache leaf, then
  scavenges recognized direct-child artifacts once per process from the native
  startup hook.

## Open and replacement

- open(path, options?) runs on the main thread, advances the generation,
  cancels active input/page work, removes the current provider/document, and
  resets overlay, page presentation, history, and dirty state.
- The local source is loaded and validated on loadQueue. Empty or unreadable
  paths, malformed or empty PDFs, and pages with invalid media boxes or
  rotations fail as invalid_source_path or unsupported_pdf.
- A load installs only when the view is alive and its generation is current.
  Page zero remains pending until its overlay is attached, its page transform
  and requested viewport are valid, and view mode is installed; only then does
  the open promise resolve with page dimensions.
- The caller-owned source URL is read directly and is never renamed, deleted,
  or placed under native cleanup scope. Failed or superseded loads release
  their PDFKit readers.

## Page switches and previews

- A programmatic page switch cancels active input and viewport animation,
  installs the target page's committed content, and applies its fit-centered
  viewport only after the target overlay and transform are usable. A
  monotonically increasing switch ID rejects stale completion.
- View mode prepares bounded previous/next snapshots from stable layout. Each
  direction has one absent, rendering, or ready preview slot; rendering
  submissions carry a generation/key/instance identity, so stale completions
  cannot mutate a newer slot or the opposite direction.
- A pull captures immutable page content, source, geometry, revision, layout
  direction, and physical direction. A committed handoff retains the selected
  snapshot until the live target overlay is ready; layout churn and detachment
  cannot replace it.

- Each page also retains immutable compatibility-text display metadata extracted
  on `loadQueue`. It is installed only for the matching active page and
  generation, cleared on detach/replacement/disposal, and is excluded from
  history, revisions, dirty state, and export.

## Disposal

- Disposal is UI-thread-owned and idempotent. It advances the generation,
  cancels input, page navigation, previews, and exports, removes the overlay
  provider, clears callbacks/presentation, and releases the document and text
  overlay.
- Stale worker results and callbacks cannot mutate the disposed view.
  Published and pending signed-output paths are deleted on the serial export
  queue. The shared cache directory, source URLs, and caller-owned files are
  never removed.
