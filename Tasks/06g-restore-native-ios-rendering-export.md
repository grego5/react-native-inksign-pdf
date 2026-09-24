# Task 06g: Restore native iOS rendering and annotation export

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Use PDFKit, Quartz, and CoreText as the single iOS PDF backend while preserving
the coordinator's immutable snapshot and transactional publication model.

## Depends on

- [Task 06](06-integrate-ios-mutable-pages.md)
- [Task 06f](06f-validate-native-ios-pdf-backend.md)

## Implementation

1. Replace PDFium-backed page presentation with native PDF rendering. Keep the
   existing viewport, caching, overlay ownership, and stale-generation rules;
   do not introduce a second document model.
2. Make `PDFDocument` and `PDFPage` authoritative for page metadata. Use one
   canonical geometry conversion for rendering, input, overlays, and export.
3. Finalize from an immutable committed snapshot and a detached working-PDF
   copy. Never inspect changing view state on the export worker.
4. For each signature, create a bounded, displayable, printable
   `PDFAnnotation`, add it with `PDFPage.addAnnotation(_:)`, and persist the
   committed variable-width contours as filled vector appearance content. Set
   the general `ReadOnly`, `Locked`, and `LockedContents` flags. Do not use a
   bitmap, rebuild the source page, or modify its content stream.
5. Add committed text as annotations. Use native free-text only when Task 6f
   proves shaping and interoperability; otherwise use a custom CoreText-drawn
   vector appearance retaining the original Unicode in `contents`. Set
   `Locked` and `LockedContents` while preserving selection and copying in
   supported ordinary viewers.
6. Write the detached annotated `PDFDocument`, reopen it, and verify page
   geometry, semantic contents, appearance streams, and persisted display,
   print, read-only, and lock flags. Publish only while the operation is current.
7. Do not validate or reconstruct unsupported forms, links, destinations,
   outlines, tags, layers, scripts, embedded files, or signatures. Their loss
   is acceptable and cannot trigger PDFium or full-page reconstruction fallback.

## Completion

- Tests cover native rendering, mixed geometry, locked-but-copyable LTR/RTL and
  fallback text, read-only locked vector signatures, stale export, cleanup,
  write/reopen, and supported-viewer interoperability.
- Production iOS rendering, export, and verification contain no PDFium call and
  make no advanced source-semantics preservation promise.

Status: Implementation follows the annotation-based contract; macOS fixture,
external-viewer, and performance validation remain pending.
