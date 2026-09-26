# Android document lifecycle

## Ownership

- `HybridInkSignView` exposes the Nitro/Fabric API and owns the document coordinator.
- The coordinator owns the published working PDF, page order, active page, histories,
  dirty state, and module-created files.
- `PdfSessionWorker` serializes PDFium sessions and document work. `SurfaceView` owns
  presentation and input; the text overlay owns draft and editor state.
- Android stages files and owns display surfaces. PDFium parses, assembles, renders,
  and exports PDFs.

## Opening

- Each `open()` gets an attempt ID and a module-owned working copy; the caller's file
  is left untouched.
- Prepare and validate the PDFium candidate while the published document and editor
  remain usable. Wait cancellably for a nonzero host viewport without changing the
  viewer, editor, or tile requests.
- Before commit, build the candidate model and fully configured viewport. The handoff
  finishes editing and blocks input and tile requests; after worker acceptance, a
  non-cancellable UI transaction installs the matching model and prepared presentation.
  It invokes no public callbacks midway. Callbacks and tile requests follow publication.
- Retire the replaced reader and working file after publication. A superseded attempt
  releases only its candidate and working copy.
- A failed initial open leaves the viewer empty. If replacement preparation or worker
  commit fails, abort the handoff, reconcile the old document's editor/undo/dirty state,
  and keep its published model and reader. Superseded attempts release only their candidate.
- Requests arriving after handoff starts wait for that handoff to finish before proceeding.
- Reopen each assembled candidate before publication and validate page count, order,
  dimensions, and rotation. Compare image-page dimensions at PDFium's serialization
  precision; use reopened metadata as the published dimensions.

## Page history and disposal

- Page identities and histories travel with pages through structural edits. Structural
  dirty state is document-level; undo and redo history is page-local.
- Clearing a page is one undoable action. Dirty state reflects remaining ink and
  document structure; clearing the last ink in an otherwise clean document leaves it clean.
- Disposal rejects pending work, clears presentation and callbacks, and closes PDFium
  readers and module-owned files.

See [viewport-input.md](viewport-input.md) for navigation and input,
[rendering-front-buffer.md](rendering-front-buffer.md) for page and ink presentation,
and [export.md](export.md) for exported-document behavior.
