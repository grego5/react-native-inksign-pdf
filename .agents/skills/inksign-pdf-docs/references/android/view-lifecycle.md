# Android view lifecycle

## Ownership

- `HybridPdfView` is the Nitro/Fabric boundary for public methods,
  callbacks, and document requests.
- `SurfaceView` coordinates the loaded document, active-page presentation,
  input routing, and lifecycle cancellation on the UI thread.
- `TextInteractionOverlay` owns editing and dragging, the temporary editor,
  keyboard interaction, and one-shot placement. It sends validated text
  mutations to `SurfaceView` and reports only the native interaction mode.
- `InkDocumentState` owns ordered pages, the active-page index, source
  path, document generation, and immutable text-field hints.
- `InkDocumentController` owns the active-page viewport, tile planning,
  cache, and presentation reset. `PageNavigationController` owns navigation
  gestures, previews, and handoff state.
- `PdfSessionWorker` owns PDF readers and PDF work off the UI thread.

The UI thread owns view state, viewport state, history presentation, and
callbacks. Worker results are accepted only when their document, page, and
request identity are current. Rendering and export details belong in
`rendering-front-buffer.md` and `export.md`.

## Invariants

- Committed ink and text are ordered entries in one history per page. Undo/redo
  describes the active page; dirty state is aggregated across pages.
- The overlay keeps at most one temporary editor and one transient interaction
  state. Empty drafts are discarded; non-empty settlement creates one history
  mutation. A retained selected payload is refreshed against the current
  generation/page annotation and cannot address an absent annotation.
- Undo, redo, clear, and text settlement use one UI-thread state transaction;
  reentrant editor callbacks cannot produce a second history mutation or
  intermediate public snapshot.

## Lifecycle rules

- A view must be attached and laid out before viewport or page-navigation work
  can proceed.
- Detachment settles text editing through
  `TextInteractionOverlay.finishForLifecycle()` and synchronizes the
  low-latency presenter. The surface also cancels active input and navigation.
- Window-focus loss cancels active ink and page navigation, and settles the
  overlay's pending placement or active editor through the same lifecycle
  transition.
- Mode changes, page changes, document replacement, and disposal cancel pending
  placement. Placement is owned by the overlay and is not mirrored in
  JavaScript or the surface.
- Page, mode, and document replacement settle active text editing, dismiss the
  keyboard, cancel any forwarded viewport stream, and clear the overlay
  editor, retained selection, and transient drag before new state is installed.
- A selected annotation is cleared when undo/redo, clear, replacement,
  detachment, or disposal makes its generation, page, or identity stale. An
  outside editor drag is cancelled before editor teardown so the viewport
  gesture detector never retains a partial stream.
- Native keyboard avoidance is enabled by default and is owned by the viewport
  controller. Disabling it clears only the transient IME adjustment so React
  can own avoidance without a second overlay translation.
- Document replacement cancels active input, invalidates prior worker results,
  resets viewport/controller state, and installs only the current generation.
- Disposal is UI-thread-owned and idempotent. It cancels input and navigation,
  invalidates the document generation, disposes the viewport/controller,
  clears callbacks and presentations, and closes worker-owned resources.
- The caller-provided source PDF is read-only and is never replaced or deleted
  by view lifecycle operations. Export output ownership is documented in
  `export.md`.
