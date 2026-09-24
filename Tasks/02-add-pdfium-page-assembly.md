# Task 02: Add shared PDFium page assembly

[Back to task index](../TASKS.md)

Status: Complete — image-only CREATE saves, reopens, and renders visible image
pixels at the requested page dimensions. Candidate validation still checks
rotation and MediaBox metadata.

## Objective

Add a worker-safe PDFium adapter that appends PDF pages, creates optimized
image pages, removes one page, moves one page, and saves a validated replacement
without modifying its input.

## Non-goals

- Do not present pickers or decode source images. Accept optimized JPEG bytes
  and placement metadata from the platform image encoder.
- Do not merge editing behavior into the render-only
  `PdfiumDocumentSession`.
- Do not add content/form editing, encryption support, or structural undo.

## Read before editing

- `core/pdfium-adapter/PdfiumDocumentSession.hpp` and `.cpp`:
  `PdfiumLibrary`, API serialization, ownership, and errors.
- `core/third_party/pdfium/include/fpdf_ppo.h`:
  `FPDF_ImportPagesByIndex`.
- `core/third_party/pdfium/include/fpdf_edit.h`: `FPDFPage_Delete`,
  `FPDF_MovePages`, `FPDFPageObj_NewImageObj`,
  `FPDFImageObj_LoadJpegFileInline`, `FPDFImageObj_SetMatrix`,
  `FPDFPage_InsertObject`, and `FPDFPage_GenerateContent`.
- `core/third_party/pdfium/include/fpdf_save.h`: `FPDF_SaveAsCopy`.
- `core/third_party/pdfium/manifest.json`, `tools/verify-pdfium.ps1`,
  `android/build.gradle`, and `android/CMakeLists.txt`.
- Android and iOS PDFium smoke tests.

## Current behavior and invariants

The shared adapter opens immutable bytes for inspection and rendering. Local
Android archives contain the required page symbols, but release metadata and
verification do not declare the full assembly surface. PDFium calls are
serialized and handles stay on their owning worker.

## Implementation

1. Add `fpdf_ppo.h` and `fpdf_save.h` to the public-header contract. Require
   page assembly symbols plus `FPDFPageObj_NewImageObj`,
   `FPDFImageObj_LoadJpegFileInline`, `FPDFImageObj_SetMatrix`,
   `FPDFPage_InsertObject`, `FPDFPage_GenerateContent`, and
   `FPDF_SaveAsCopy` in release, local, Gradle, Android, and iOS verification.
2. Verify the pinned iOS XCFramework exports the same symbols. Rebuild and
   republish pinned artifacts only when a required symbol is absent; never add
   a second PDFium binary.
3. Add a one-shot `PdfiumPageAssembler` under `core/pdfium-adapter` with one
   command model: append ordered source PDFs, remove one index, or move one
   index to another. Reuse the shared library lease and mutex, retain all
   backing bytes until handles close, and execute on the caller's serial worker.
4. Append one source PDF to the destination copy at its current page count via
   `FPDF_ImportPagesByIndex`. Import every source page in order; reject empty,
   unreadable, encrypted, or invalid sources without publishing output.
5. Add one image page by creating a page with the target width and height,
   creating an image object, loading the optimized JPEG with
   `FPDFImageObj_LoadJpegFileInline`, applying the encoder's contain placement
   matrix, inserting the object, and generating page content. The file-access
   callback must point at the append input's JPEG bytes for the duration of the
   inline load; PDFium copies the image data before that call returns. Keep JPEG
   data inline so staged image files can be deleted after assembly.
6. Remove one validated index with `FPDFPage_Delete`; reject the sole-page case
   as `last_page_required`.
7. Move one validated page with `FPDF_MovePages`. Define the assembler's target
   index as the final zero-based index and centralize the single required
   PDFium index translation inside the adapter. Lock forward, backward, and
   same-index behavior with tests.
8. Save to an exact scratch path via non-incremental `FPDF_SaveAsCopy`. Reopen
   and validate count, rotated display dimensions, rotation, MediaBox, append
   order, removal, and move order before success.
9. Never overwrite or delete input files. Platform owners perform atomic
   publication and retire prior working artifacts.

## Rules

- Preserve the render session's read-only contract.
- Return detached metadata/errors only; no PDFium handle crosses a bridge.
- Pin experimental import/move API availability in artifact verification.

## Tests

- Add native fixtures with distinguishable pages.
- Verify multipage append order and vector source preservation.
- Verify image pages contain optimized JPEG content, render visible pixels
  after save/reopen, preserve the target page dimensions and contain placement,
  and do not retain staged image files.
- Verify first/middle/last removal and sole-page rejection.
- Verify forward, backward, and same-index moves.
- Verify failed mutation leaves input unchanged and publishes no valid output.
- Link every required symbol in Android and iOS smoke tests.

## Validation

- Run `tools\verify-pdfium.ps1 -Mode local -Platform android`.
- Run applicable native adapter/smoke tests through repository runners.
- Validate iOS archive symbols on CI/macOS; report Windows limitations.
- Run `git diff --check -- ':!nitrogen/generated/**'`.

## Completion criteria

- One shared adapter performs all PDF page-structure mutations transactionally.
- Artifact metadata and verification guarantee every used header and symbol.

Proposed commit: `feat(pdfium): add transactional page assembly`
