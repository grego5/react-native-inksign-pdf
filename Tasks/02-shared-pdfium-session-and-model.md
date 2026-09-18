# 02 — Create the shared PDFium document session and positioned-text model

[Back to plan index](../TASKS.md)

Status: Planned

Depends on: [Task 01](01-package-pdfium.md)

## Objective

Add a shared C++20, thread-confined PDFium document owner and immutable
platform-neutral positioned-text value model without connecting it to UI code.

## Non-goals

- Do not implement platform drawing, font fallback, or shaping.
- Do not eagerly extract every page.
- Do not expose PDFium handles, STL containers, or pointers to Kotlin or Swift.

## Read before editing

- `cpp/` and `android/src/main/cpp/cpp-adapter.cpp`: shared-library and JNI conventions.
- `android/src/main/java/com/margelo/nitro/inksignpdf/PdfSession.kt`: worker/session lifetime.
- `ios/PdfView+Document.swift` and `ios/DocumentState.swift`: iOS generation and ownership.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`: canonical geometry and threading.

## Current behavior and invariants

- Android and iOS own independent platform PDF sessions and generation guards.
- PDF I/O and parsing stay off the UI/main thread.
- Compatibility runs are immutable presentation data outside content history and export.

## Implementation steps

1. Add a shared `PdfiumLibrary` owner that initializes PDFium once per process,
   reference-counts document sessions, and destroys global state after the last closes.
2. Add move-only `PdfiumDocumentSession` ownership for `FPDF_DOCUMENT` and its
   input backing store. Require methods and destruction on the creating serial worker.
3. Define C++ value types for point, rectangle, affine matrix, RGBA color,
   text render mode, positioned character, and positioned page. Character
   records include source index, stable page-local text-object ordinal, Unicode
   mapping, generated/map-error flags, font metadata, optional colors, optional
   next displacement, origin, bounds, matrix, and font size.
4. Keep document generation outside geometry values. Define a result envelope
   carrying platform generation, page index, and an immutable page snapshot.
5. Add RAII page/text-page guards whose handles never survive extraction.
   Returned snapshots own no PDFium resources.
6. Update the architecture reference with native ownership and lifetime invariants.

## Ownership, lifecycle, and API rules

- A session owns file bytes or seekable backing storage for the document lifetime.
- `FPDF_PAGE` and `FPDF_TEXTPAGE` close in reverse order on success or failure.
- Shared values use repository-owned types; no PDFium struct enters their API.
- Do not alter public Nitro sources or generated bindings.

## Tests and validation

- Add native lifecycle tests for invalid input, successful open/close, repeated
  sessions, early extraction failure, and destruction order.
- Assert value snapshots survive temporary page-handle closure.
- Run focused native lifecycle tests, Android build, and `git diff --check`.

## Completion criteria

- PDFium global/document/page ownership is explicit and leak-safe.
- The normalized model has no platform or PDFium types.
- Document construction does not extract page text.

## Proposed commit title

`feat(native): add pdfium text session model`
