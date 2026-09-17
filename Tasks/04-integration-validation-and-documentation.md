# 04 — Lock export isolation, documentation, and device acceptance

[Back to plan index](../TASKS.md)

Status: Planned

Depends on: [Task 02](02-android-compatibility-overlay.md) and
[Task 03](03-ios-compatibility-overlay.md)

## Objective

Verify the completed compatibility overlay as one cross-platform display
feature, lock its exclusion from export and application state, and update the
maintained contracts and user-facing limitations.

## Non-goals

- Do not broaden the heuristic into font-file inspection or pixel-based source
  glyph detection.
- Do not add a public feature toggle in this plan.
- Do not modify or normalize the caller's source PDF.
- Do not fix Android user-annotation export fonts as part of this feature.
- Do not claim that all arbitrary PDF text layouts, vertical writing, Type 3
  fonts, or already-visible non-ASCII text are supported.

## Read before editing

- `TASKS.md` and Tasks 01–03 for the accepted v1 policy.
- `src/PdfView.nitro.ts` to confirm no public API changed.
- `android/src/main/java/com/margelo/nitro/inksignpdf/PdfExport.kt` and
  Android export tests.
- `ios/PdfView+Export.swift`, `ios/TextRendering.swift`, and export-related
  lifecycle tests.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`, Android/iOS
  rendering references, and Android/iOS export references.
- `README.md` for the current user-facing rendering/export description.

## Current behavior and invariants

- `finalize()` preserves the original source page and adds only committed
  application ink/text.
- Export snapshots are captured from page history and contain no presentation
  caches or live views.
- State callbacks report only undo/redo, dirty state, and interaction mode.
- Public PDF bytes, high-frequency geometry, and native presentation details
  do not cross JavaScript.

## Implementation steps

1. Add explicit source-contract tests on both platforms proving compatibility
   run types are absent from `PdfExportSnapshot`/`ExportSnapshot`, history
   snapshots, dirty-state calculations, and state callbacks.
2. Finalize the Task 01 fixture after compatibility overlays have been tested
   on both platforms. Keep only data required by tests and document every
   intentionally unsupported layout feature.
3. Run end-to-end device acceptance with the synthetic fixture and the local
   problematic PDF without committing the latter. Verify:
   - non-ASCII text becomes visible;
   - ASCII digits, punctuation, email addresses, and vector rules are not
     visibly doubled;
   - fit, zoom, pan, tile-level changes, rotation, page switches, and RTL/LTR
     page-turn previews preserve alignment;
   - entering draw/text modes and editing user annotations do not change the
     source overlay;
   - reopening or replacing a document cannot flash stale compatibility text.
4. Finalize on both platforms and compare the result with a baseline finalize
   from before the feature. Page count, media boxes, rotations, source text
   object counts, and committed application markup must match. The compatibility
   overlay must not be present in exported page objects or raster layers.
5. Measure open-time extraction and tile/preview rendering with and without
   compatibility candidates. Confirm extraction occurs once per document and
   Android does not re-enumerate page objects per tile. Record only pass/fail
   thresholds in tests; do not add dated benchmark numbers to maintainer docs.
6. Update `.agents/skills/inksign-pdf-docs/references/architecture.md` to list
   compatibility source text as native, immutable, display-only metadata that
   stays outside history, dirty state, JavaScript, and export.
7. Update Android and iOS rendering/lifecycle references with the implemented
   extraction, layering, preview, cancellation, and failure rules. Keep export
   references explicit that source compatibility overlays are excluded.
8. Update `README.md` with a concise user-facing note: the viewer can overlay
   extractable non-ASCII source text when a PDF font is unavailable; it relies
   on `/ToUnicode`/platform extraction, preserves ASCII from the source render,
   is display-only, and does not repair the finalized PDF.
9. Do not run Nitrogen unless implementation unexpectedly changes the public
   TypeScript spec. If it does, stop and revise this plan rather than widening
   the feature silently.

## Ownership, threading, lifecycle, coordinates, and API rules

- Keep compatibility extraction native and off the UI/main thread.
- Keep overlay presentation generation-bound and page-local.
- Do not introduce a second persisted content/history model; compatibility
  data is derived from the current source document.
- Preserve canonical coordinates and existing platform viewport transforms.
- The source file and finalized output remain owned exactly as documented
  before this feature.

## Tests and expected observable results

- Existing history, state, navigation, and export suites pass unchanged except
  for new compatibility-specific assertions.
- Finalize output contains no compatibility overlay objects or images.
- Device screenshots/pixel tests show compatible alignment at fit and zoomed
  tile levels and during page-turn previews.
- Documents with ASCII-only text produce no compatibility runs and no changed
  tile/preview pixels.
- Documents whose platform extractor returns no Unicode continue to display
  through the original renderer without open failure.

## Validation

Run:

```powershell
tools\test-android.ps1 -Mode jvm
tools\test-android.ps1 -Mode connected
tools\test-android.ps1 -Mode build
tools\test-ios-lifecycle.ps1
npx tsc --noEmit --pretty false
npm run build
npm run verify:change
git diff --check -- ':!nitrogen/generated/**'
```

Run the iOS LifecycleTests pod XCTest and visual/pixel acceptance on macOS/Xcode.
Report any unavailable connected-device or Apple-platform validation separately;
do not substitute source inspection for runtime rendering evidence.

## Completion criteria

- Android and iOS display the synthetic and local problematic PDFs according
  to the same eligibility policy.
- Active-page and preview presentation agree at all tested transforms.
- No public API, history, state, source file, or finalized PDF behavior changed.
- Maintainer and user-facing documentation match the implemented limits.
- All available validation passes and unavailable platform checks are reported.

## Proposed commit title

`docs: finalize source text compatibility overlay contract`
