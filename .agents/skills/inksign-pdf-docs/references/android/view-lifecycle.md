# Android document lifecycle

## Ownership

`HybridInkSignView` adapts the Nitro/Fabric API and owns the long-lived
document coordinator. The coordinator owns the published document, ordered
pages, active page, dirty state, and module-created working artifacts.

`SurfaceView` owns Android presentation and input routing. `PdfSessionWorker`
owns serialized PDFium sessions and document work. PDF open, page assembly,
rendering, and export use PDFium; Android owns file staging and bitmap surfaces.
The text overlay owns temporary editor state.

## Publication

Opening a document creates a module-owned working copy; the caller's source
remains untouched. Replacement and page changes are prepared as detached
candidates. The coordinator publishes the candidate document, page order, active
page, and worker session together only after validation. Until then, the current
document remains published. A failed, cancelled, or stale operation cannot
partially replace it.

The PDFium assembler reopens each saved candidate before publication and checks
its page count, order, dimensions, and rotation. Image page dimensions are
compared at the precision PDFium can serialize and report; published page
dimensions come from the reopened candidate.

Page identities and their histories follow the pages through structural changes.
Structural dirty state belongs to the document and remains separate from
page-local undo and redo.

Clearing a page records one undoable clear action: the page becomes empty and
`canUndo` remains true. Dirty state reflects remaining ink across pages and
document structure, so clearing the final ink in an otherwise clean document
returns the document to clean state.

Navigation previews retire a failed loading slot. The next gesture retries a
missing preview only when its down-time page-edge eligibility matches that
target; late preview callbacks cannot replace a newer slot.

## Presentation and disposal

PDFium supplies the base page imagery; annotation presentation is layered above
it. Active input and editor state are temporary until committed to page history.
Disposal invalidates pending work, clears UI callbacks and presentation, and
releases native resources.

See [export.md](export.md) for the separate export snapshot and output contract.
