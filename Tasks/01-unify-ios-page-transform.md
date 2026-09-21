# Task 01: Unify the iOS page transform

[Back to task index](../TASKS.md)

Status: Complete

## Objective

Replace the competing transform paths with one tested transform model for PDF
rendering, viewport conversion, ink, text, and hit testing. Correct upright,
unmirrored rendering for unrotated and rotated pages.

## Non-goals

- Do not redesign tile caching or scheduling.
- Do not change gesture ownership or text sizing.
- Do not preserve an existing transform helper solely for internal
  compatibility; migrate its callers or remove it.

## Read before editing

- `ios/PdfiumPageView.swift`: `applyViewport`, point/rectangle conversion,
  `updatePageLayout`, and `pdfiumTransform`.
- `ios/InkSignView+Overlay.swift`: `refreshOverlayTransform` and transform
  invalidation.
- `ios/PagePreview.swift`: PDF-to-display and canonical-to-display helpers.
- `ios/Geometry.swift`: `PageGeometry`.
- `ios/tests/InkSignViewLifecycleTests.swift`: viewport and overlay coverage.
- Maintainer references: `references/architecture.md` and
  `references/swift-ios/viewport-input.md` under the repository maintainer
  skill.

## Current behavior and invariants

Stored content uses media-box-relative, top-left page coordinates. The current
implementation separately derives viewport, PDFium, and overlay mappings; the
diagnostic unrotated PDF is displayed inverted/mirrored. `applyViewport` must
remain the only page-view viewport mutation, and stale generations must not
become current presentation.

## Implementation

1. Add one immutable `PageViewportTransform` value in `ios/Geometry.swift`.
   It owns page geometry, normalized rotation, zoom, canonical focus, page
   frame, canonical-to-view, view-to-canonical, and PDF-to-display mapping.
   `InkPdfView` owns the sole current optional instance.
2. Have `InkPdfView.applyViewport` construct this value once per accepted
   mutation. Make unusable geometry impossible to publish at the ownership
   boundary instead of scattering guards through consumers.
3. Expose explicit canonical-to-view, view-to-canonical, PDF-to-view, and
   canonical-rectangle-to-view operations on that value. Migrate every caller
   to them and remove independent rotation switches from `InkPdfView`, overlay
   code, and preview code.
4. Correct PDFium matrices for rotations 0, 90, 180, and 270, including
   non-zero media-box origins. Keep Core Graphics bitmap orientation separate
   from PDF page-coordinate conversion.
5. Set `pageToOverlayTransform` directly from the snapshot plus the UIKit view
   conversion between `documentView` and the overlay. Delete the three-point
   sampled reconstruction in `refreshOverlayTransform`.
6. Invalidate the snapshot on page replacement, unusable layout, generation
   change, and disposal. A worker receives detached numeric values only, never
   UIKit, PDFKit, or session-owned objects.
7. Remove superseded conversion state and helpers after migrating all callers;
   do not keep parallel legacy paths or silent fallback transforms.

## Rules

- Viewport state is main-thread-owned; PDF rendering remains on its serial
  worker.
- Rotation and media-box translation are applied exactly once.
- Canonical coordinates and public viewport snapshots do not include view
  transforms.
- Replace tests and reference statements that encode competing transforms or
  incorrect orientation; they do not justify preserving those paths.
- Do not edit generated Nitro output.

## Tests

- Add these cases to the new focused
  `ios/tests/InkSignViewStabilizationTests.swift` suite; do not expand the
  legacy lifecycle suite.
- Add corner and center mapping assertions for rotations 0, 90, 180, and 270.
- Assert canonical-to-view-to-canonical round trips within a small tolerance.
- Cover non-zero media-box origins and both fit and zoomed viewports.
- Assert overlay, canonical, and PDF coordinate mappings agree.
- Use `diagnostics/RaDaLqz0kjfZbrgDjeEd.pdf` for runtime verification that page
  1 is upright and unmirrored. Keep it manual unless suitability for automated
  redistribution and deterministic rendering is confirmed.

## Validation

Perform static review only: enumerate every caller of removed conversion and
rotation helpers; verify each is migrated or explicitly assigned to Tasks 2
through 4; check matrix composition and inverse round-trip algebra by
inspection. Do not run iOS tests locally. Record expected temporary compile or
test failures for Task 5 instead of adding adapters.

## Completion criteria

- All iOS presentation consumers use one validated transform snapshot.
- Every supported rotation and non-zero origin passes round-trip tests.
- Tests encode the corrected mapping; runtime orientation validation is owned
  by Task 5.

Proposed commit: `fix(ios): unify page and viewport transforms`
