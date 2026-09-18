# 02 — Render compatibility text in Android tiles and previews

[Back to plan index](../TASKS.md)

Status: Implemented; JVM/APK pass; connected fixture pending on current device

Depends on: [Task 01](01-establish-overlay-contract-and-fixture.md)

## Objective

Extract immutable source-text runs when `PdfSession` opens a document and
paint eligible non-universal glyphs into each display tile immediately after
`PdfRendererPreV` renders it. Because previews use the same session rendering
path, live pages and neighboring previews must receive identical overlays.

## Non-goals

- Do not edit, normalize, or replace the source PDF.
- Do not add compatibility text to `InkHistory`, `TextAnnotation`, dirty state,
  undo/redo, or export snapshots.
- Do not expose extracted source text to JavaScript or the UI thread.
- Do not attempt source-font embedding detection or pixel-based missing-glyph
  detection.
- Do not change user-created text layout or Android export font behavior in
  this task.

## Read before editing

- `android/src/main/java/com/margelo/nitro/inksignpdf/PdfSession.kt`:
  `PdfSession.open`, `renderTiles`, and `renderPreview`.
- `android/src/main/java/com/margelo/nitro/inksignpdf/PdfTiles.kt`:
  `PdfTileRequest` scale and tile-origin semantics.
- `android/src/main/java/com/margelo/nitro/inksignpdf/InkDocumentController.kt`:
  tile-to-view presentation and cache ownership.
- `android/src/main/java/com/margelo/nitro/inksignpdf/SurfaceView.kt`:
  `onDraw` ordering and page-navigation preview rendering.
- `android/src/main/java/com/margelo/nitro/inksignpdf/TextLayout.kt`:
  default typeface, bidi heuristics, paint construction, and immutable layout
  patterns.
- `android/src/test/kotlin/com/margelo/nitro/inksignpdf/PdfSessionWorkerTest.kt`
  and Android instrumentation rendering tests for current seams.
- `.agents/skills/inksign-pdf-docs/references/android/view-lifecycle.md`,
  `android/viewport-input.md`, `android/rendering-front-buffer.md`, and
  `android/diagnostics-validation.md`.

## Current behavior and invariants

- `PdfSession` and every `PdfRendererPreV.Page` are worker-owned.
- A tile bitmap is transferred to UI ownership only after rendering completes;
  stale results are recycled.
- Active pages, cached tiles, and page-turn previews share canonical page and
  tile request identities.
- `SurfaceView.onDraw` paints PDF tiles first, completed ink second, and
  committed user text third.
- Export opens a separate session and is not part of display tile rendering.

## Implementation steps

1. Add a focused production file such as `PdfCompatibilityText.kt` containing:
   - an immutable worker-owned run with decoded text, selection-derived
     position, and replacement font size;
   - the eligibility/masking policy established in Task 01;
   - a renderer that accepts a `Canvas`, page dimensions, and the exact
     page-to-tile matrix used by `PdfRendererPreV`.
2. During `PdfSession.open`, obtain the page text stream and resolve the full
   stream with `page.selectContent()`. Convert its returned per-character
   bounds into immutable runs before closing the page. If selection returns no
   usable bounds, create no compatibility runs for that page.
3. Keep extracted runs private to `PdfSession`; do not add them to
   `PdfSessionInfo` or `InkDocumentState`. This keeps source text on the PDF
   worker and prevents a new UI or JavaScript data boundary.
4. In `renderTiles`, render the source page first. Then attach a `Canvas` to
   the same bitmap and draw the prepared runs with the same scale and tile
   translation as `page.render`.
5. Preserve the full Unicode string for shaping and advances, but make ASCII
   U+0020...U+007E, whitespace/control scalars, and any scalar lacking a
   default-font glyph transparent. Use Android's bidi-aware text layout or
   text-run APIs; do not manually reverse RTL strings. Render replacement
   text in opaque black.
6. Use selection's top-left page coordinates directly. The whole-page line
   rectangles provide vertical placement and replacement font size; each
   scalar's resolved start/stop points provide its visual horizontal interval.
7. Keep `renderPreview` delegating to `renderTiles`; do not add a second preview
   implementation. Confirm preview keys, cancellation epochs, and stale bitmap
   recycling remain unchanged.
8. Add a bounded worker diagnostic for omitted malformed runs in debug builds
   only. Do not log document text or emit one message per tile.
9. Update the Android rendering maintainer reference to state that source-text
   compatibility runs are baked into display tiles on the PDF worker, below
   ink and committed user text, and never enter history or export.

## Ownership, threading, lifecycle, coordinates, and API rules

- Extraction and overlay rasterization remain on `PdfSessionWorker`; no
  `PdfRendererPreV.Page` or page object crosses threads.
- Runs are immutable after open and die with their `PdfSession` generation.
- Tile cache identity does not need a new revision because runs are immutable
  for the document generation.
- Draw in PDF page units and reuse the exact tile transform; never route source
  text through viewport state or JavaScript.
- Preserve the existing draw order: compatibility text is part of the PDF tile
  presentation, below ink and user-created text.
- Leave `PdfExporter`, `PdfExportSnapshot`, and public Nitro sources unchanged.

## Tests and expected observable results

- Keep only focused JVM coverage for Unicode scalar masking and malformed
  Unicode. Device validation is visual and is performed on a real Android
  device.
- Add a worker replacement/cancellation test proving a stale generation cannot
  publish a tile with an old document's compatibility runs.
- Retain existing `SurfaceView`, tile-cache, page-navigation, and export tests
  without changing their expected history or dirty-state values.

## Follow-up implementation brief

Real-device validation showed that scalar-level selection geometry produces
tiny, unshaped, and poorly positioned Hebrew glyphs. The corrective work is
tracked separately in [Task 02a](02a-android-grouped-compatibility-extraction.md)
and [Task 02b](02b-android-shaped-compatibility-rendering.md). Do not extend the
scalar-layout approach described above.

## Validation

Run:

```powershell
tools\test-android.ps1 -Mode jvm
tools\test-android.ps1 -Mode connected
tools\test-android.ps1 -Mode build
git diff --check -- ':!nitrogen/generated/**'
```

If no Android S-extension-18 device or emulator is available, report visual
device validation as pending; JVM checks do not prove selection geometry or
rendering alignment.

## Completion criteria

- Eligible non-universal source glyphs appear in active tiles and page-turn
  previews using the platform default font.
- Universal ASCII glyphs are not doubled.
- Zoom/tile-level transitions do not shift or duplicate the overlay.
- Overlay data remains worker-owned and generation-bound.
- History, state callbacks, and exported PDFs are unchanged.

## Proposed commit title

`feat(android): overlay incompatible source PDF text`
