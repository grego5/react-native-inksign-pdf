# iOS document lifecycle

## Ownership

`InkSignView` adapts Nitro commands and coordinates document operations. The
document coordinator owns the published document, ordered page records, active
page, page histories, generation, and module-created artifacts. The PDFium
session owns native document access. UIKit presentation owns the viewport, page
tiles, and retained ink canvas; the text overlay owns temporary editing state.

## Publication

Opening copies the caller's PDF into a module-owned working document.
Replacement and structural page changes prepare and validate a candidate before
publishing it. The coordinator changes the working document, PDFium session,
page order, active page, and structural dirty state as one transition. The
existing document remains published during preparation; failed, cancelled, or
stale work leaves it intact.

Page identity and page-local history follow a page through append, removal, and
movement. Structural changes are tracked at document level, outside page-local
undo and redo. PDF inputs retain their pages and order; image inputs become PDF
pages through the native import path.

## Presentation and navigation

PDFium provides the base page imagery. PencilKit and text editing are presented
in native overlays; transient input is separate from committed page history. A
page switch is complete only after the target PDF page, its overlay, and
viewport are installed. Results from older document or page requests cannot
install over current state.
A page-change callback follows only a real installed switch.

Disposal invalidates pending operations and releases document, worker, and
presentation resources. See [export.md](export.md) for finalize behavior.
