# 02 — Render compatibility text in Android tiles and previews

[Back to plan index](../TASKS.md)

Status: Planned

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
   - an immutable worker-owned run with decoded text, copied six-value PDF
     matrix, font size, fill/stroke presentation, and bold/italic hints;
   - the eligibility/masking policy established in Task 01;
   - a renderer that accepts a `Canvas`, page dimensions, and the exact
     page-to-tile matrix used by `PdfRendererPreV`.
2. During `PdfSession.open`, call `page.getPageObjects()` once per page and
   convert `PdfPageTextObject` entries into immutable runs. Copy every mutable
   platform value before closing the page. Reject only the individual run when
   text is empty, matrix values are non-finite, font size is non-positive, the
   render mode is unsupported, or no non-universal scalar is drawable by
   `TextLayoutSpec.typeface`.
3. Keep extracted runs private to `PdfSession`; do not add them to
   `PdfSessionInfo` or `InkDocumentState`. This keeps source text on the PDF
   worker and prevents a new UI or JavaScript data boundary.
4. In `renderTiles`, render the source page first. Then attach a `Canvas` to
   the same bitmap and paint only runs intersecting the tile request. Apply the
   same scale and tile translation as `page.render`, plus the empirically
   verified PDF-bottom-left to canonical-top-left conversion from Task 01.
5. Preserve the full Unicode string for shaping and advances, but make ASCII
   U+0020...U+007E, whitespace/control scalars, and any scalar lacking a
   default-font glyph transparent. Use Android's bidi-aware text layout or
   text-run APIs; do not manually reverse RTL strings. Preserve source fill
   color when valid and use opaque black only when the source API reports no
   usable fill color.
6. Apply the source object's matrix before drawing so translated, scaled,
   rotated, or sheared text follows the PDF geometry. If Android's reported
   matrix/font-size split differs across device API levels, codify the observed
   S-extension-18 behavior in one conversion helper and its instrumentation
   tests rather than compensating in callers.
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

- Add JVM tests for Unicode scalar masking, default-font glyph gating, color
  fallback, immutable matrix copying, and malformed-run omission.
- Add an instrumentation bitmap test using the Task 01 fixture that asserts:
  - the non-ASCII region gains dark pixels after compatibility painting;
  - ASCII digit/punctuation regions are byte-identical to the normal PDF render;
  - vector border pixels remain unchanged;
  - two tile scales place the overlay at the same canonical coordinates;
  - `renderPreview` produces the same overlay as an equivalent visible tile.
- Add a worker replacement/cancellation test proving a stale generation cannot
  publish a tile with an old document's compatibility runs.
- Retain existing `SurfaceView`, tile-cache, page-navigation, and export tests
  without changing their expected history or dirty-state values.

## Validation

Run:

```powershell
tools\test-android.ps1 -Mode jvm
tools\test-android.ps1 -Mode connected
tools\test-android.ps1 -Mode build
git diff --check -- ':!nitrogen/generated/**'
```

If no Android S-extension-18 device or emulator is available, report the
instrumentation and pixel assertions as unvalidated; JVM tests alone do not
prove platform page-object extraction or rendering alignment.

## Completion criteria

- Eligible non-universal source glyphs appear in active tiles and page-turn
  previews using the platform default font.
- Universal ASCII glyphs are not doubled.
- Zoom/tile-level transitions do not shift or duplicate the overlay.
- Overlay data remains worker-owned and generation-bound.
- History, state callbacks, and exported PDFs are unchanged.

## Proposed commit title

`feat(android): overlay incompatible source PDF text`
