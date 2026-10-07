# Android rendering and front buffer

## PDF pages

- `PdfSessionWorker` serializes PDFium rendering into `ARGB_8888` bitmaps; the
  native bridge converts bitmap byte order. PDFium handles Y conversion;
  Android supplies positive display scale and tile offsets.
- Each native document session retains one render-page handle and its PDFium
  parsed-page/decoded-image cache. Changing the source page releases it;
  session close releases it before the document under the PDFium mutex.
  This native cache is separate from Android bitmap budgets and diagnostics.
- `SurfaceView` owns the full-page base cache, keyed by document generation,
  stable page ID, and geometry/orientation. Viewport and history changes reuse
  source pixels. See [cache lifetime](view-lifecycle.md#ownership).
- Base rasters preserve aspect ratio, capped at a 2048 px longest edge and 4 Mi pixels.
  The 32 MiB cache counts allocations and in-flight reservations, protects
  active/presented pages, and defers destinations when full. Navigation borrows
  bitmaps; eviction removes unpresented borrowers before recycling.
- Tiles have a separate device-based soft budget, capped at 48 MiB; visible
  tiles stay protected during trimming. Diagnostics count bitmap allocations
  and base reservations.
- Draw base → detailed tiles → module ink/text through the page transform.
  The base fills uncovered pan regions; zoom retains old detail until the new
  level covers the viewport. Destination acquisition follows the current pull
  and pauses during open handoff; editing retains active-page coverage.
- Grid tiles use 512 px cores with 2 px page-clamped bleed, clipped at shared
  core edges. Full-page previews have no bleed. Cache accounting uses allocated
  bitmap sizes.
- Latest viewport demand includes a two-tile prefetch margin. Dispatch one tile
  at a time, visible first, yielding to document operations between renders.
  Raster invalidation and coverage revision are separate: retain useful
  in-flight pan results; discard stale document/page results and obsolete demand.
  Attempt prefetch once per window, including successful results later evicted;
  missing visible tiles remain eligible.
- PDFium owns embedded fonts. An optional app fallback supplies immutable bytes
  for non-embedded requests; unsupported glyphs may remain missing. Otherwise,
  use PDFium's default provider. See [font-file ownership](view-lifecycle.md#ownership).

## Ink front buffer

- Display one complete committed or prediction snapshot. Closed fill contours
  use the same native cubics for display, history, and export.
- Each accepted move batch produces one committed frame and at most one
  replaceable prediction; terminal input produces the final history frame.
  Ordinary `onDraw` excludes active ink.
- Prediction is presentation-only. Clear it before committed frames and on
  terminal input, cancellation, reset, replacement, presenter loss, mode change,
  or disposal.
- Input requires a presenter. Bound pending work and accept callbacks only for
  the current generation/sequence. Terminal success commits history and clears
  transient contours; delayed acknowledgements cannot restore them.
- Page switches cancel active input/handoff and rebuild from page-local history.
  See [history and disposal](view-lifecycle.md#page-history-and-disposal).
