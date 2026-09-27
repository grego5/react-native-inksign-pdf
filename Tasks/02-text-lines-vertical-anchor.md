# Limit and vertically anchor programmatic text

[Task index](../TASKS.md)

Status: Planned
Complexity: High

## Objective and non-goals

Add `maxLines?: number` and `verticalAnchor?: 'top' | 'bottom'` to `TextAnnotationOptions` for both Android text entry points: imperative `addTextAnnotation()` and manual `insertAnnotationOn(options?)`. Omitted or zero `maxLines` adds no line-count limit; positive values retain the first N complete laid-out lines. With a top anchor, the requested vertical edge stays fixed and text grows downward; with a bottom anchor, the bottom edge stays fixed and text grows upward. Retained lines stay in reading order; overflow omits later lines at the bottom.

Use the same `direction`, `xLimit`, `yLimit`, `maxLines`, and `verticalAnchor` options for both paths. For bottom anchoring, `yLimit` is the upper hard edge and defaults to page top; for top anchoring, it remains the lower hard edge and defaults to page bottom. Both geometric and line-count limits apply, so the smaller visible set wins. An `insertAnnotationOn()` call without options preserves the current tap-centered editor behavior. Do not implement iOS native behavior in this task.

## Read before editing

- `src/InkSignView.nitro.ts`: `TextAnnotationOptions`, `insertAnnotationOn`; `src/index.ts`: `addTextAnnotation` and manual-placement dispatch validation.
- `android/src/main/java/com/margelo/nitro/inksignpdf/TextInteractionOverlay.kt`: `programmaticTextFlowBounds`, `addTextAnnotation`, `armPlacement`, `placeTextAt`, edit/drag/resize paths; `InkHistory.kt`: `TextAnnotation`.
- `android/src/main/java/com/margelo/nitro/inksignpdf/TextLayout.kt`: layout, visible bounds, drawing; `PdfExport.kt`: `PdfExportTextResolver` line selection and baselines. Read bounded source context only for the next decision.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`, `android/export.md`, and `development.md`; inspect focused text-placement and PDF-export tests.

## Current behavior and invariants

Programmatic text stores logical text, direction, visible bounds, and a page-point flow rectangle. Rendering and export wrap to its width and show only complete lines within its height. Manual placement currently arms a one-shot tap, opens an editor on touch end, and centers the initial box near that tap; it has no flow options. Committed annotation state is page-local and must survive editing, dragging, resizing, undo/redo, and export. The JavaScript host validates public arguments before native dispatch.

## Implementation

1. Add the two optional Nitro fields and change the manual method to `insertAnnotationOn(options?: TextAnnotationOptions)`. Validate both entry points through one public option validator: `maxLines` is a non-negative integer; `verticalAnchor` is `top` or `bottom`; retain the existing direction and finite-limit rules. Regenerate Nitrogen during implementation; adapt generated iOS method signatures only as needed for compilation, leaving iOS behavior for its later task.
2. Extend Android `TextAnnotation` with the line limit and anchor so they persist in page history. Keep `flowBounds` as the hard page-space region. In programmatic admission, resolve its vertical interval from `position.y` toward `yLimit` according to anchor. A top anchor permits `0 <= position.y < page.height`; a bottom anchor permits `0 < position.y <= page.height`. Reject a zero or inverted region through the existing bounds error. The horizontal interval and direction behavior stay as they are.
3. Give Android layout one authoritative selection of visible complete lines: in source order, at most `maxLines` when positive, and only while their full line height fits the vertical region. Derive visible bounds and the on-screen clip from that selection. For `bottom`, translate the retained block upward so its bottom meets `position.y`; as text gains lines, its top moves upward while the bottom remains fixed. Never show a line outside `flowBounds` or crop a partial line.
4. Apply the same selected lines and vertical translation in PDF export so preview and output agree. Preserve logical text, direction, color, and PDF text extraction order. Ensure edit commit, move, and font-size change retain both new fields and recompute visible bounds from the current text and region; reopening an annotation must not silently drop its line or anchor settings.
5. Capture manual options when `insertAnnotationOn(options?)` arms placement. With supplied options, use the tap's canonical page point as the horizontal start and selected vertical edge; resolve the opposite edges from `xLimit` and `yLimit` or the page. A tap that cannot define a non-empty region leaves placement armed for another tap. Apply the same line selection and hard limits to the live editor and committed annotation. A later `setTextDirection()` call updates active input as before and recomputes directional growth without moving the input frame at the instant of the switch. The no-options path keeps its existing initial placement and editor behavior.
6. Update `README.md`, the architecture reference, and the Android viewport/export references to describe both Android entry points and the pending iOS parity.

## Tests and verification

Use short text with explicit line breaks and a fixed page, font, and flow region to assert deterministic line selection. One imperative case should show bottom-anchored upward growth and retention of the first lines; a restrictive upper `yLimit` should reduce that set. One manual tap case should show the live editor and committed annotation honoring the same options, including a fixed bottom edge and hard horizontal limit. Verify a representative annotation after edit/reopen and PDF export. Reuse existing no-options manual placement, direction, top-anchor, and dimension tests as regression coverage. Inspect one representative rendered page on a device for placement and clipping quality, using tolerant geometric expectations rather than exact glyph pixels.

Run `npm run nitrogen` to produce the required bindings. Intended checks after the no-tests/builds restriction is lifted: `npm run test:public-api`, `npx tsc --noEmit --pretty false`, and `tools\test-android.ps1 -Mode connected -Test com.margelo.nitro.inksignpdf.TextPlacementInstrumentationTest` plus the focused PDF export instrumentation class. If a device or runner is unavailable, report the exact unrun gate. During the current restriction, use static inspection and `git diff --check -- ':!nitrogen/generated/**'` only.

Complete when Android imperative and manual text share the line/anchor/limit contract, screen and PDF export agree, no-options manual placement remains stable, and deferred validation is reported truthfully. Proposed commit: `feat(android): limit and vertically anchor text placement`.
