# 08 — Retire heuristic providers and complete device acceptance

[Back to plan index](../TASKS.md)

Status: Planned

Depends on: [Task 05](05-android-positioned-cluster-rendering.md), [Task 07](07-ios-positioned-cluster-rendering.md)

## Objective

After both shared paths pass real-device acceptance, remove superseded Android
selection and iOS PDFKit geometry reconstruction, lock export isolation, and
align maintainer documentation with the final architecture.

## Non-goals

- Do not replace base-page rendering with PDFium.
- Do not write compatibility text into source or finalized PDFs.
- Do not add public configuration or JavaScript callbacks.

## Read before editing

- `PdfCompatibilityText.kt`, `PdfSession.kt`, and compatibility tests.
- `ios/CompatibilityText.swift`, document/preview/overlay consumers, and tests.
- `PdfExport.kt`, `ios/PdfView+Export.swift`, and export references.
- Architecture, Android/iOS rendering, and validation references.

## Current behavior and invariants

- Shared geometry is primary after Tasks 05 and 07.
- Compatibility presentation remains outside content/history/export.
- Heuristic providers are migration-only, not permanent parallel implementations.

## Implementation steps

1. Record Android and iOS device acceptance for the supplied fixture: active
   page, preview, zoom/tile transitions, replacement, and reopen. Resolve shared
   contract defects before removing fallbacks.
2. Remove Android selection/text-content compatibility geometry, run-level
   `StaticLayout` preparation, heuristic diagnostics, and algorithm-only tests.
3. Remove iOS attributed-string/character-bounds compatibility geometry and heuristic-only tests.
4. Make shared extraction failure omit compatibility presentation for that page
   with one bounded debug diagnostic while still opening the base PDF.
5. Confirm compatibility snapshots are unreachable from history, dirty state,
   callbacks, or either export snapshot.
6. Rewrite maintainer references as current-state contracts for PDFium ownership,
   lazy cache, canonical geometry, shaping, draw order, lifecycle, and diagnostics.
7. Remove stale comments and fixtures only when they no longer support shared regression validation.

## Tests and validation

- Keep focused tests for extraction lifecycle, transforms, cache invalidation,
  clusters, and export isolation.
- Remove heuristic-specific and pixel-comparison tests; add no screenshot assertions.
- Run native suites, Android JVM/build/connected checks, iOS lifecycle/device
  checks, applicable TypeScript/build checks, and `git diff --check`.
- Completion requires actual Android and iOS visual acceptance; report unavailable environments exactly.

## Completion criteria

- One shared geometry implementation serves both platforms.
- No platform geometry heuristic remains in production.
- Supplied-PDF presentation is accepted against Acrobat on Android and iOS.
- Public API, history behavior, and finalized PDFs remain unchanged.

## Proposed commit title

`refactor(native): retire heuristic pdf text geometry`
