# Android view lifecycle

## Ownership

- `HybridInkSignView` is the public Nitro/Fabric adapter. One persistent
  `MutableDocumentCoordinator`, created at that boundary, owns the optional
  published document, module-owned working artifacts, ordered stable-ID page
  records, active page, structural dirty state, operation admission, and
  document generations. It also delegates the current/prepared PDF session
  lifecycle to `PdfSessionWorker`.
- `SurfaceView` consumes coordinator queries and snapshots for UI-thread
  presentation and routes page/history intents back through coordinator
  commands. It owns viewport, tile presentation, input routing, and
  cancellation only; `InkDocumentController` owns viewport and tile state;
  `PageNavigationController` owns navigation and handoff state.
- `TextInteractionOverlay` owns the temporary editor, text gestures, keyboard,
  and one-shot placement. `PdfSessionWorker` owns serialized PDFium execution,
  PDF readers, prepared sessions, and native session resources.
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
- Opening copies the caller's PDF into a coordinator-owned working artifact
  before publication. Structural commands capture stable page identities and
  immutable inputs, assemble and open a unique prepared candidate without
  replacing the current render session, validate the complete page aggregate,
  commit the prepared worker session, and publish the candidate path, stable
  page records, active page, generation, and dirty state as one coordinator
  transition. Failed preparation, validation, commit, cancellation, or stale
  completion retains the published state and retires only the candidate.
- Working and appended PDF inputs cross JNI as module-owned file paths; only
  normalized JPEG image payloads cross as managed byte arrays.
- The coordinator admits only one open, page-input staging, structural
  mutation, or export operation at a time. Picker staging, image
  normalization, file I/O, PDFium assembly, and session replacement stay off
  the UI thread; picker cancellation, superseding open, and disposal retire
  coordinator-owned temporary files.
- Structural and export operations reserve coordinator admission before text
  settlement or any other callback-producing UI preflight. Failed preflight
  releases that reservation before returning an error.
- PDFium page pixels are the only base-page presentation. Android annotation
  state is composited after tile publication and never participates in PDFium
  page parsing or text reconstruction.
- Disposal is UI-thread-owned and idempotent. It cancels input/navigation,
  invalidates the generation, clears callbacks/presentation, and closes worker
  resources.
- The caller's source PDF is read-only and is never replaced or deleted by
  lifecycle operations. The current working PDF is the only document consumed
  by rendering, mutation, and export; export output ownership is defined in
  [export.md](export.md).
