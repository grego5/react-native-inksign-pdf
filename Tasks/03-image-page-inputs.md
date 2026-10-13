# 03 - Return encoded image-page inputs

[Plan](../TASKS.md)

Status: Completed (static); runtime acceptance deferred
Complexity: Medium
Depends on: 01

## Objective and non-goals

Separate image encoding from PDF construction. Initial image loading and append
use one JPEG-to-PDFium path. Preserve quality, resolution, and public options.

## Read before editing

- `ios/MutablePageImageEncoder.swift`: `InkSignPdfMutablePageImageEncoder.encode`.
- `ios/InkSignView+Document.swift`: initial image branch.
- `ios/MutableDocumentTransactions.swift`: image append branch.
- `core/pdfium-adapter/PdfiumPageAssembler.hpp`: image input and `Create`.
- Android `ImagePageEncoder.kt`: JPEG/page placement contract.

## Current contract

Encoding applies EXIF correction, contain fit, white margins, a shared longest-edge
cap, and JPEG quality. Omitted DPI keeps the 200-DPI raster; explicit DPI is capped
by contained source resolution. The result currently becomes a PDFKit image page.

## Implementation

1. Return JPEG data, page size, and placement instead of `PDFPage`. Preserve
   sizing, orientation, margins, default quality 0.72, and supplied options.
2. Map the page-sized raster to the full canonical page rectangle. Apply rotation
   as page metadata rather than stretching or rotating the JPEG again.
3. Extend the bridge with image input and shared assembler creation. Native code
   owns copied bytes during the synchronous operation and releases them afterward.
4. Replace initial-image PDFKit `dataRepresentation()` with assembler creation.
   Task 04 consumes the same encoded value for image append.
5. Remove the JPEG-to-UIImage/PDFPage step after callers migrate. Core Graphics
   and ImageIO remain image encoders, not source-PDF rewriting backends.

## Static validation and completion

- Both image entry paths share one encoder; PDF sources bypass it.
- Page geometry and raster aspect ratio remain independent of preview dimensions.
- Run `git diff --check`.
- Proposed commit: `refactor(ios): feed encoded image pages to PDFium`.

## Implementation result

- ImageIO returns the existing page-sized JPEG and placement without decoding
  it back into UIImage/PDFPage. Initial JPEGs use shared PDFium creation.
- The shared assembler accepts image rotation metadata; Android's default zero
  remains unchanged. Raster sizing, EXIF, contain fit, and quality are preserved.
- No tests/builds ran; existing image fixtures require output-model migration.
