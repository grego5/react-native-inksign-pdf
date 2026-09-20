# Android view lifecycle

## Ownership

- `HybridInkSignView` is the public Nitro/Fabric boundary. `SurfaceView` owns
  UI-thread presentation, input routing, history projection, and cancellation.
- `InkDocumentState` owns the source path, ordered pages, active page, and
  document generation. `InkDocumentController` owns viewport and tile state;
  `PageNavigationController` owns navigation and handoff state.
- `TextInteractionOverlay` owns the temporary editor, text gestures, keyboard,
  and one-shot placement. `PdfSessionWorker` owns PDF readers and the native
  PDFium raster session.
- Worker results are accepted only when their document, page, and request
  identity are current.

## Invariants

- Committed ink and text are ordered entries in one history per page. Undo/redo
  describes the active page; dirty state is aggregated across the document.
- The overlay has at most one temporary editor and one transient interaction.
  Empty drafts are discarded and non-empty settlement creates one history
  mutation.
- Undo, redo, clear, and text settlement are one UI-thread state transaction;
  reentrant callbacks cannot create a second mutation or intermediate snapshot.

## Lifecycle rules

- Viewport and navigation work require an attached, laid-out view. Detachment
  or window-focus loss settles text input and cancels active ink/navigation.
- Mode changes, page changes, replacement, and disposal cancel pending text
  placement and clear stale editor/selection state before new state is installed.
- Document replacement cancels active work, invalidates prior worker results,
  resets presentation, and installs only the current generation.
- PDFium page pixels are the only base-page presentation. Android annotation
  state is composited after tile publication and never participates in PDFium
  page parsing or text reconstruction.
- Disposal is UI-thread-owned and idempotent. It cancels input/navigation,
  invalidates the generation, clears callbacks/presentation, and closes worker
  resources.
- The source PDF is read-only and is never replaced or deleted by lifecycle
  operations; export output ownership is defined in [export.md](export.md).
