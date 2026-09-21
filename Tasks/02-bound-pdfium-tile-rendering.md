# Task 02: Bound PDFium tile rendering

[Back to task index](../TASKS.md)

Status: Complete

## Objective

Replace the current zoom-scaled allocation model with a bounded PDFium tile
pipeline whose geometry, scheduling, and cache ownership remain correct at all
supported zoom levels.

## Non-goals

- Do not alter gesture routing, ink history, or text layout.
- Do not introduce a second viewport transform.

## Read before editing

- [Task 01](01-unify-ios-page-transform.md) and its implemented transform.
- `ios/PdfiumPageView.swift`: tile keys, `renderTiles`, installation, cache
  eviction, and request validity.
- `ios/PdfiumRenderSession.h` and `ios/PdfiumRenderSession.mm`: detached render
  request and buffer contract.
- `ios/PagePreview.swift`: independent preview rendering lifecycle.
- Maintainer reference `references/swift-ios/rendering.md`.

## Current behavior and invariants

Tile origin and size currently multiply logical tile dimensions by zoom before
pixel allocation, allowing extreme bitmap sizes near zoom 16. Obsolete visible
tiles are removed before replacements arrive, exposing the background. Results
must remain generation-, page-, and zoom-bound, and the cache is presentation
state only.

## Implementation

1. Use a page-anchored grid of 512-by-512 device-pixel tiles. For a quantized
   render zoom, canonical tile extent is `512 / (zoom * screenScale)` on each
   display axis; increasing zoom therefore reduces canonical coverage instead
   of increasing bitmap size.
2. Quantize render zoom upward to the next one-eighth zoom step, capped at 16,
   so cached pixels are never lower resolution than the requested viewport.
   Edge tiles may be smaller, but no dimension may exceed 512 pixels.
3. Cap decoded tile cache cost at 64 MiB and queued/pending requests at 8.
   Keep PDFium execution serial; do not add parallel session access. Use exact
   decoded byte cost (`stride * height`) for accounting. Tile
   planning must produce valid dimensions by construction; keep one checked
   multiplication at the allocation boundary as a hard failure.
4. Key requests by document generation, page index, quantized zoom, column,
   and row. Coalesce identical pending work; do not key by transient view frame
   or pan offset.
5. Check request currency before rendering and again before installation.
   Page, generation, transform, or scale changes make the result disposable.
6. Retain the last valid visible tile set beneath pending replacements. Remove
   old tiles only after matching current tiles are installed or after the page
   is replaced/disposed.
7. Evict least-recently-used entries by total image bytes while protecting
   current and fallback-visible
   tiles. Bound pending work so rapid pinches cannot create an unbounded queue.
8. Clear pending keys, images, views, fallback state, and render tokens during
   page replacement and disposal.

## Rules

- PDFium session work stays on its creating serial worker.
- Worker closures carry detached values, not UIKit views or PDF handles.
- Main-thread installation is conditional on the current immutable request
   identity. Replace incompatible cache/request structures rather than wrapping
   them in another compatibility layer.
- Allocation rejection must fail the tile quietly without invalidating the
  document or removing valid fallback presentation.
- Remove tests that require the old zoom-scaled tile grid, cache identity, or
  eager removal behavior; validate the new bounded pipeline instead.

## Tests

- Add tile-planning and invalidation cases to
  `InkSignViewStabilizationTests`; keep them deterministic and independent of
  network, signing, and physical rendering timing.
- Assert tile dimensions and total planned bytes remain within limits at zoom
  0.1, fit, 1, 2, and 16.
- Cover integer overflow and invalid/empty dimensions without allocation.
- Verify duplicate requests coalesce and pending work remains bounded.
- Verify rapid scale changes and page/generation replacement cannot install
  stale results.
- Verify cache eviction preserves current and fallback-visible tiles.
- Add a runtime stress scenario that repeatedly pinches and pans between fit
  and maximum zoom without flashes, memory growth, or crashes.

## Validation

Perform static review only: trace request identity from planning through worker
completion, prove every allocation is at most 512 by 512 pixels, verify the
8-pending-request and 64-MiB bounds, verify PDFium access remains serial, and
inspect all invalidation paths. Do not run iOS
tests locally or create transitional cache adapters. Task 5 owns compilation,
tests, and stress validation.

## Completion criteria

- Maximum zoom cannot request an oversized bitmap or unbounded work queue.
- Stale tiles never install.
- The new planner, request, and cache model is complete; integrated visual and
  stress acceptance is owned by Task 5.

Proposed commit: `fix(ios): bound and stabilize PDFium tiles`
