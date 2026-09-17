# 06 — Connect lazy shared geometry to the iOS document lifecycle

[Back to plan index](../TASKS.md)

Status: Planned

Depends on: [Task 03](03-canonical-text-extraction.md)

## Objective

Expose the shared extractor through a narrow Objective-C++ facade and integrate
lazy generation-bound page caching with the iOS document lifecycle.

## Non-goals

- Do not expose C++ types or PDFium handles directly to Swift.
- Do not replace PDFKit/Core Graphics base-page rendering.
- Do not yet remove the PDFKit compatibility extractor.

## Read before editing

- `ios/PdfView+Document.swift`: document load, replacement, generation, and worker flow.
- `ios/DocumentState.swift`: immutable page state.
- `ios/CompatibilityText.swift`: existing extractor and fallback model.
- `ios/PagePreview.swift` and `ios/PdfView+Overlay.swift`: consumers.
- iOS lifecycle and rendering maintainer references.

## Current behavior and invariants

- iOS extracts compatibility runs eagerly from `PDFPage.attributedString`.
- PDFKit presentation and PencilKit overlays remain platform-owned.
- Stale work must not install after document replacement or disposal.

## Implementation steps

1. Add an Objective-C++ facade owning `PdfiumDocumentSession`. It accepts the
   immutable source input, extracts one page synchronously on its serial queue,
   and copies records into Swift-owned immutable values.
2. Keep STL types, references, and PDFium handles private to Objective-C++.
   Define explicit open, extraction, cancellation, and close results.
3. Replace eager compatibility extraction with a bounded page-index LRU. Load
   active page on demand and prefetch immediate neighbors after active work.
4. Envelope results with existing iOS generation and reject stale installation.
5. Fall back to the PDFKit extractor when shared open/extraction fails; never combine providers.
6. Close native session and clear caches on replacement, reset, and disposal on its queue.
7. Update iOS lifecycle/rendering references with lazy ownership and fallback precedence.

## Ownership and threading rules

- Swift receives copied values with no native lifetime dependency.
- PDFium operations remain on one serial owner; UI installation remains main-thread-owned.
- Cache capacity is bounded and follows the same policy as Android.

## Tests and validation

- Add lifecycle tests for first access, reuse/eviction, prefetch, fallback,
  stale generation, replacement, and disposal.
- Assert multi-page open does not extract all text pages.
- Run iOS lifecycle tests on macOS/Xcode and `git diff --check`; report unavailable validation.

## Completion criteria

- iOS retrieves the same normalized geometry contract as Android.
- No PDFium/C++ object crosses into Swift.
- Existing visual overlay remains available during migration.

## Proposed commit title

`feat(ios): bridge lazy pdfium text geometry`
