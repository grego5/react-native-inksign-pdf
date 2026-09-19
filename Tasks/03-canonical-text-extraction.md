# 03 — Extract canonical character geometry and bounded diagnostics

[Back to plan index](../TASKS.md)

Status: Complete

Depends on: [Task 02](02-shared-pdfium-session-and-model.md)

## Objective

Implement lazy per-page PDFium extraction into complete canonical positioned
character snapshots and provide a safe diagnostic dump for geometry comparison.

## Non-goals

- Do not form shaping clusters or choose replacement fonts.
- Do not draw overlays or change platform caches.
- Do not infer displacement across uncertain source boundaries.

## Read before editing

- Shared model and RAII owners created by Task 02.
- `tools/testdata/pdf-font-overlay/`: compatibility fixtures.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`: coordinate contract.
- Pinned PDFium headers for character, matrix, font, color, generated, and object APIs.

## Current behavior and invariants

- Canonical coordinates are media-box-relative, top-left origin, positive Y down.
- Shared extraction must preserve character-level source geometry rather than inferred runs.
- Document text must not be emitted unrestricted to logs.

## Implementation steps

1. Implement `extractPage(pageIndex)` with temporary page/text-page handles and
   enumerate `FPDFText_CountChars` in stable stream order.
2. Copy Unicode, generated/map-error state, origin, loose bounds with a
   documented character-bounds fallback, effective matrix, font metadata,
   colors, and render mode. Assign stable page-local text-object ordinals.
3. Convert the page box, every rectangle corner, origin, matrix, and displacement
   vector with one explicit PDF-user-space-to-canonical transform. Axis-align
   bounds only after transforming all corners.
4. Derive optional next displacement only for adjacent non-generated records
   from the same object with compatible transforms and plausible same-line
   placement. Leave it absent across uncertainty or large positioning jumps.
5. Preserve unknown optional values rather than inventing defaults. Retain
   invisible text metadata so replacement detection can omit it.
6. Add a debug-only bounded dump with page/index, code points, geometry, matrix,
   style, object ordinal, and displacement validity; never dump unrestricted text.
7. Produce dumps for the failing fixture and synthetic rotated, transformed,
   colored, invisible, and mixed-direction fixtures.

## Ownership, coordinates, and failure rules

- Extraction is synchronous on the owning serial worker and returns detached data.
- Invalid optional character metadata stays absent; an invalid page fails only that extraction.
- Cancellation prevents publication but still closes temporary handles.

## Tests and validation

- Add native tests for Y inversion, matrix composition, transformed bounds,
  vector conversion, object ordinals, displacement boundaries, invisible mode,
  and cleanup after partial failure.
- Verify diagnostics are bounded and code-point based.
- Run native geometry/lifecycle suites, Android build, and `git diff --check`.

## Completion criteria

- The supplied fixture yields plausible character origins, transforms, and styles.
- Rotated/skewed synthetic text remains consistent after conversion.
- Returned pages contain no live PDFium resources.

## Delivered

- Added lazy `PdfiumDocumentSession::extractPage()` with scoped page and
  text-page ownership, stable stream-order records, page-local object
  ordinals, and detached immutable snapshots.
- Added media-box-relative top-left conversion for page bounds, character
  origins, bounds, and effective matrices. Character bounds use
  `FPDFText_GetLooseCharBox` only when `FPDFText_GetCharBox` is unavailable.
- Converted only the effective matrix's page-space output to canonical
  coordinates. Per-character origins are stored separately because PDFium can
  reuse one effective matrix across characters with different origins.
- Preserved PDFium uncertainty in optional colors, font metadata, render mode,
  and next-character displacement; displacement is emitted only across
  compatible non-generated same-line records from one text object.
- Added a bounded debug diagnostic dump that prints code points and geometry
  without emitting unrestricted document text, plus host coverage for its
  truncation behavior and Android PDFium smoke coverage for zero-offset,
  rotated, transformed, and nonzero-media-box extraction.

Validation: Android debug native compilation and final linking pass with the
pinned NDK `30.0.16138531`; `:app:assembleDebug` completes for `arm64-v8a` and
`x86_64`. `git diff --check` passes.

## Proposed commit title

`feat(native): extract canonical pdf text geometry`
