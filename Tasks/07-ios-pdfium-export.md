# 07 - Finalize through PDFium

[Plan](../TASKS.md)

Status: Completed (static; runtime gates pending)
Complexity: High
Depends on: 04, 06

## Objective and non-goals

Finalize committed iOS content through the common writer, adopting embedded page
text/vector ink as approved. Preserve live drawing, history, viewport behavior,
and the existing output publication contract.

## Read before editing

- `ios/NativePDFExporter.swift`: `write` and output validation.
- `ios/InkSignView+Export.swift`: `ExportPageSnapshot`, worker and publication.
- `ios/SignatureVectorPath.swift`: `filledStrokes`, colors, supported pen policy.
- `ios/PDFVectorAnnotation.swift`: replaced appearance writer.
- `ios/Geometry.swift`: `PageGeometry`, canonical/PDF coordinate mapping.
- Tasks 05-06's writer/resources; maintainer `swift-ios/export.md` and shared
  artifact/cancellation contracts.

## Current contract

Finalize writes a separate committed snapshot and returns a published file URI.
Live strokes/drafts are excluded. Supported circular PencilKit contours are
vector approximations; unsupported brushes fail. Module content is embedded
through the common PDFium writer.

## Implementation

1. Replace PDFKit writing in `InkSignPdfNativeExporter.write` with the bridge and
   common writer. Read working bytes on the PDF queue; supply immutable page
   snapshots, CoreText resources, and existing PencilKit filled contours.
2. Preserve per-stroke color and supported-ink checks. The common path model
   supports per-path colors; Android supplies its existing uniform color to each
   path. Do not rasterize signatures or read live canvases during export.
3. Validate captured source geometry. Map saved text layout and canonical ink to
   PDF coordinates including media-box offsets; set final page rotation once.
   Do not bake the same rotation into both content and `/Rotate`.
4. Carry source content and source annotations through PDFium without flattening
   through Quartz. New module text/ink is embedded page content with shared
   Unicode mappings and vector geometry.
5. Perform common output validation and PDFKit reopening before publication.
   Preserve page order/count/boxes and source-content expectations. Replace new
   module annotation-count/lock validation with embedded-content validation.
6. Preserve pending-output registration, freshness checks, worker retention,
   cleanup, and URI normalization. Export does not mutate working bytes,
   history, dirty baseline, or prepared handles.
7. Remove unused module appearance code after callers migrate; retain unrelated
   annotation/history models with callers. Suite adaptation is deferred to
   Task 08, so intermediate verification sources may require migration.
8. The later core phase moves snapshot construction/publication out of InkSignView.
   Keep writer inputs presentation-free now. PDFKit output reopening is a backend
   interoperability gate in this phase and becomes viewer validation in Task 12;
   final headless publication must depend only on native validation.

## Static validation and completion

- Trace text-only, ink-only, mixed, rotated, failed, and cancelled exports through
  the common writer and existing publication owner.
- Product PDF manipulation no longer serializes through PDFKit/Quartz. PDFKit
  loading/rendering and CoreText layout retain their current owners.
- Run `git diff --check`.
- Proposed commit: `feat(ios): finalize text and vector ink through PDFium`.

## Implementation result

- PDFium writes detached working bytes with owned CoreText glyph/font resources,
  canonical PencilKit contours, per-stroke colors, and final rotation metadata.
- Common validation inspects forms and composed text transforms. PDFKit reopening
  checks page boxes and source annotations before existing artifact publication.
- Font preparation errors remain identifiable through finalize rejection.
- Verification sources check embedded content; the former appearance type is
  removed with its migrated callers.
- Authored whitespace checks passed. Compilation, exact font embedding, form
  clipping, PDFKit interoperability, and Android writer regression checks are
  deferred to the authorized backend checkpoint.
