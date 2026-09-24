# iOS document lifecycle

## Ownership

`InkSignView` adapts Nitro commands and coordinates document operations. The
document coordinator owns the published PDFKit document, ordered stable page
records, active page ID, page histories, generation, and module-created
artifacts. UIKit presentation owns the viewport, page tiles, and ink canvas;
the text overlay owns temporary editing state.

## Publication

Opening copies the caller's PDF into a module-owned working document.
Replacement and structural page changes prepare and validate a native candidate
before publishing it. The existing document remains published during
preparation; failed, cancelled, or stale work leaves it intact. Publication
replaces document, page order, active page, and structural dirty state together.

Page identity and page-local history follow a page through append, removal, and
movement. Structural changes are tracked at document level, outside page-local
undo and redo. PDF inputs retain their pages and order; image inputs become PDF
pages.

## Presentation and navigation

PDFKit and Quartz provide the base page imagery. PencilKit and text editing are
presented in native overlays; transient input is separate from committed page
history. A page switch is complete only after the target page, its overlay, and
viewport are installed. Results from older document or page requests cannot
install over current state.
A page-change callback follows only a real installed switch.

Disposal invalidates pending operations and releases document, worker, and
presentation resources. See [export.md](export.md) for finalize behavior.
