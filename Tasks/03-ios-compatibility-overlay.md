# 03 — Render compatibility text in the iOS page overlay and previews

[Back to plan index](../TASKS.md)

Status: Implemented; macOS/Xcode and device pixel validation pending

Depends on: [Task 01](01-establish-overlay-contract-and-fixture.md)

## Objective

Extract immutable compatibility text during PDF loading, present it beneath
PencilKit and user-created text in the retained PDFKit page overlay, and draw
the same snapshot into page-turn previews without modifying the document or
export pipeline.

## Non-goals

- Do not add PDF annotations or mutate `PDFDocument`/`PDFPage`.
- Do not add compatibility runs to `InkSignPdfPageContentHistory`, content
  revisions, dirty state, or export snapshots.
- Do not add a public API or expose source text to JavaScript.
- Do not manually reverse Hebrew, Arabic, or other RTL text.
- Do not promise exact original-font metrics or support already-visible
  non-ASCII source text without duplication in this first version.

## Read before editing

- `ios/PdfView+Document.swift`: `loadQueue` extraction and generation install.
- `ios/DocumentState.swift`: page-local immutable and history-owned state.
- `ios/PageOverlay.swift`: `InkCanvasView` and `PageOverlayProvider`.
- `ios/PdfView+Overlay.swift`: attachment identity and
  `pageToOverlayTransform` ownership.
- `ios/PdfView.swift`: view hierarchy, `canvasView`, and
  `textInteractionOverlay` installation.
- `ios/TextRendering.swift`: Core Text shaping and canonical coordinate
  transforms.
- `ios/PagePreview.swift` and `ios/PageNavigationLifecycle.swift`: immutable
  preview request capture and worker rendering.
- `ios-tests/PdfViewLifecycleTests.swift`: overlay and preview test seams.
- `.agents/skills/inksign-pdf-docs/references/swift-ios/view-lifecycle.md`,
  `swift-ios/rendering.md`, and `swift-ios/configuration-validation.md`.

## Current behavior and invariants

- PDFKit owns source-page display and supplies one retained active-page overlay.
- The overlay provider is weakly held by PDFKit and currently returns one
  retained `InkCanvasView` only for the active page.
- `pageToOverlayTransform` is the sole validated mapping from canonical
  top-left page coordinates into overlay coordinates.
- PencilKit, committed user text, and page-turn previews consume immutable
  page snapshots; transient editors and selections are presentation-only.
- Export reopens the original source and has no dependency on the live overlay.

## Implementation steps

1. Add a focused production file such as `CompatibilityText.swift` containing:
   - an immutable canonical run representation separate from
     `InkSignPdfTextAnnotation`;
   - Unicode eligibility/masking logic matching Task 01;
   - PDFKit extraction that groups contiguous attributed characters only while
     font-size/color attributes and geometric baseline continuity match;
   - a Core Text renderer that preserves the full string for natural bidi and
     shaping while painting universal or unavailable glyphs transparently.
2. Run extraction inside the existing `loadQueue` page loop. Use
   `PDFPage.attributedString` plus `characterBounds(at:)` or bounded
   `PDFSelection` ranges to derive text, font size, color, and page-space
   geometry. Convert lower-left PDF page coordinates into canonical
   media-box-relative top-left coordinates before constructing immutable runs.
3. Split runs on explicit newline, large geometric gaps, baseline changes,
   attribute changes, or invalid character bounds so independent form columns
   are never merged merely because PDFKit reports one textual line. Use strong
   Unicode direction to anchor RTL runs to their extracted right edge; let Core
   Text perform glyph ordering and shaping.
4. Omit an individual run when PDFKit returns no Unicode, invalid bounds,
   non-positive font size, or no non-universal scalar supported by the system
   font. A failed compatibility extraction must not reject a PDF that otherwise
   passes the current load contract.
5. Store runs as immutable display metadata on `InkSignPdfPageState`, outside
   history and `contentRevision`. They are installed only with the matching
   document generation and released on replacement/disposal.
6. Replace the provider's single returned canvas with a retained
   `InkSignPdfPageOverlayView` container. It must own, in back-to-front order,
   a noninteractive compatibility text view and the existing transparent
   `InkCanvasView`; `textInteractionOverlay` remains a child of the canvas.
   Keep `PdfView.canvasView` as the stable canvas accessor so existing input and
   PencilKit ownership do not spread to callers.
7. Update provider callbacks to identify the retained container while invoking
   existing owner lifecycle methods with its canvas. Preserve stale-detach
   checks, delayed-overlay open readiness, hit testing, autoresizing, and
   PencilKit delegate ownership.
8. When the overlay attaches or its validated transform changes, install the
   active page's immutable runs in the compatibility view and render them with
   `pageToOverlayTransform`. Clear them on detach, replacement, and disposal.
   The compatibility view must never accept touches or obscure the canvas's
   input behavior.
9. Add compatibility runs to `InkSignPdfPageTurnPreviewRequest` as an immutable
   display snapshot. In `InkSignPdfPageTurnPreviewView.render`, draw them after
   the source PDF page and before committed PencilKit ink and user-created
   text. Include a compatibility-run fingerprint in the preview key only if
   extraction can change without a document generation; otherwise rely on the
   existing generation/page identity.
10. Update the iOS rendering and lifecycle maintainer references to describe
    extraction ownership, container layering, preview participation, and
    explicit exclusion from history/export.

## Ownership, threading, lifecycle, coordinates, and API rules

- PDF text inspection runs on `loadQueue`; UIKit view mutation and overlay
  installation remain main-thread-owned.
- Do not retain `PDFSelection` or temporary attributed-string objects in page
  state; retain only immutable strings, colors, sizes, and canonical geometry.
- Use the established page-to-overlay transform; do not derive a second
  viewport mapping in the compatibility view.
- The compatibility view is below PencilKit and user text and has
  `isUserInteractionEnabled = false`.
- Compatibility runs do not increment page content revision and do not affect
  page-navigation identity beyond their document generation.
- Leave `PdfView+Export.swift`, `ExportSnapshot`, and generated Nitro files
  unchanged.

## Tests and expected observable results

- Add XCTest coverage for extraction grouping, canonical conversion,
  universal-glyph transparency, system-font glyph gating, natural RTL
  direction, and malformed-run omission using the Task 01 fixture.
- Extend lifecycle tests to prove:
  - the provider returns the retained container and still exposes the same
    canvas owner;
  - attach installs only the active page's runs;
  - stale detach cannot clear a newer page's overlay;
  - replacement and disposal clear compatibility presentation;
  - hit testing and PencilKit interaction are unchanged.
- Add preview assertions proving the target page's compatibility snapshot is
  captured and rendered below committed ink/user text.
- Add a pixel test at two preview scales that verifies non-ASCII glyph pixels
  appear, ASCII regions are not doubled, and the fixture's vector border is
  unchanged.
- Assert export capture contains only source URL, page geometry, committed
  drawing, and committed user annotations—never compatibility runs.

## Validation

Run on the repository host:

```powershell
tools\test-ios-lifecycle.ps1
git diff --check -- ':!nitrogen/generated/**'
```

Run the LifecycleTests pod XCTest and the new pixel tests on macOS/Xcode. Test
portrait and rotated pages on an iOS device or simulator. If Apple-platform
execution is unavailable, report that limitation; source-contract checks do
not validate PDFKit extraction, Core Text shaping, or overlay compositing.

## Completion criteria

- Eligible source text appears in the live PDFKit overlay and page-turn
  previews using the system font.
- ASCII/whitespace glyphs remain transparent in the compatibility layer.
- Page replacement, switching, delayed attachment, and disposal cannot show
  stale runs.
- PencilKit, text editing, history, callbacks, and export behavior are
  unchanged.

## Proposed commit title

`feat(ios): overlay incompatible source PDF text`
