# 04 — Connect lazy shared geometry to the Android PDF session

[Back to plan index](../TASKS.md)

Status: Complete

Depends on: [Task 03](03-canonical-text-extraction.md)

## Objective

Expose immutable positioned-text snapshots through JNI and make the Android
PDF worker lazily request, prefetch, cache, and invalidate them without yet
replacing the existing overlay renderer.

## Non-goals

- Do not expose geometry to JavaScript or the UI thread.
- Do not replace `PdfRendererPreV` or implement positioned-cluster drawing.
- Do not remove the existing Android heuristic extractor yet.

## Read before editing

- `android/src/main/cpp/cpp-adapter.cpp`: JNI initialization and ownership.
- `android/src/main/java/com/margelo/nitro/inksignpdf/PdfSession.kt`: session flow.
- `android/src/main/java/com/margelo/nitro/inksignpdf/PdfCompatibilityText.kt`: fallback.
- Android lifecycle, viewport, and rendering maintainer references.

## Current behavior and invariants

- `PdfSession` and `PdfRendererPreV.Page` are serial-worker-owned.
- Current compatibility runs for all pages are built eagerly during open.
- Tile and preview publication already reject stale generations.

## Implementation steps

1. Add a narrow JNI facade that creates/closes the shared session and copies
   one extracted page into immutable Kotlin values. Retain no direct buffers or pointers.
2. Create the native session from the same immutable source generation used by
   `PdfRendererPreV`, with independently valid backing storage/descriptors.
3. Replace eager compatibility extraction with a bounded worker-owned LRU keyed
   by page index. Request the active page on demand and prefetch immediate
   neighbors after active-page work is scheduled.
4. Carry Android document generation in request/result envelopes and discard
   stale completion before cache insertion or tile publication.
5. On extraction failure, use the existing heuristic provider for that page and
   emit one bounded debug diagnostic. Do not fail PDF open.
6. Close the native session and clear geometry/fallback caches during reset,
   replacement, cancellation, and disposal on the owning worker.
7. Update Android lifecycle/rendering references with lazy ownership and fallback precedence.

## Ownership and threading rules

- JNI calls occur only from the worker owning the native session.
- Kotlin owns copied immutable values; native page/text handles never cross JNI.
- Cache capacity is fixed, documented beside the cache, and independent of page count.

## Tests and validation

- Add worker tests for first access, cache hit, LRU eviction, adjacent prefetch,
  failure fallback, replacement, cancellation, and disposal.
- Assert PDF open no longer extracts every page.
- Run Android JVM tests, debug APK build, focused native tests, and `git diff --check`.

## Completion criteria

- Android retrieves shared geometry lazily for the active page.
- Long-document open cost excludes total-document text extraction.
- Existing visual behavior remains available during migration.

## Delivered

- Added a worker-owned `PdfiumGeometrySession` JNI facade. Native PDFium page
  and text handles stay on the worker; one bounded binary copy is decoded into
  immutable Kotlin values containing PDFium-provided character fields.
- Open now reads one source-byte snapshot for the shared session while keeping
  an independently owned `PdfRendererPreV` descriptor. Opening remains
  successful when PDFium geometry is unavailable.
- Replaced eager all-page compatibility extraction with a fixed-capacity,
  three-page worker LRU. The active page is prepared before tile/preview work,
  and immediate neighbors warm shared geometry only after the active request is
  queued; legacy fallback runs remain active-page demand-loaded.
- Generation envelopes reject stale preparation and prefetch work. Session
  replacement, cancellation, and disposal close native resources and clear
  geometry/fallback cache state.
- The existing heuristic compatibility renderer remains the presentation path
  during migration. Its page-local runs are lazy and cached; unavailable shared
  geometry falls back without failing PDF open or tile rendering.
- Added JVM coverage for LRU behavior and worker prefetch, plus connected
  coverage for the Kotlin/JNI/PDFium copied geometry payload.

Validation: Android JVM tests, debug APK build, focused native geometry suite,
focused connected PDFium smoke tests, and `git diff --check` pass.

## Proposed commit title

`feat(android): bridge lazy pdfium text geometry`
