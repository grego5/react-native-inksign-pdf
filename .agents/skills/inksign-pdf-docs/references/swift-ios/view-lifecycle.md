# iOS document lifecycle

## Ownership

`InkSignView` adapts Nitro commands and coordinates document operations. The
document coordinator owns the published PDFKit document, ordered stable page
records, active page ID, page histories, generation, and module-created
artifacts. UIKit presentation owns the viewport, page tiles, and ink canvas;
the text overlay owns temporary editing state.

## Publication

Opening copies the caller's PDF into a module-owned working document.
Replacement and structural page changes prepare and validate a detached
candidate. The current document remains published until validation succeeds;
failed, cancelled, or stale operations leave it intact. Publication replaces
the document, page order, active page, and structural dirty state together.

Page identity and page-local history follow a page through append, removal, and
movement. The coordinator tracks structural changes separately from page-local
content history. PDF inputs contribute pages in requested order; image inputs
become PDF pages.

## Presentation and navigation

PDFKit and Quartz provide the base page imagery. PencilKit and text editing are
presented in native overlays; transient input is separate from committed page
history. A page switch installs its target page, overlay, and viewport as one
presentation transition. The current page request alone updates presentation.
A page-change callback follows an actual installed switch.

Disposal invalidates pending operations and releases document, worker, and
presentation resources. See [export.md](export.md) for finalize behavior.
