# Task 06f: Validate the native iOS PDF backend

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Prove the Apple PDF backend for the required basic workflow before removing the
in-progress iOS PDFium path: merge PDF pages, add image pages, preserve visible
page geometry, and export this module's locked text and vector signatures.

## Contract

- Use direct cross-document `PDFPage` insertion, removal, and reinsertion.
  `PDFPage.dataRepresentation()` is not a page-transfer mechanism.
- Preserve visible page content, page order, supported boxes, and rotation.
- Do not promise preservation of forms, field relationships, links,
  destinations, outlines, tagged structure, layers, scripts, embedded files,
  or existing digital signatures. Their loss or invalidation must not block the
  native workflow or become an implicit test requirement.
- Export signatures through `PDFPage.addAnnotation(_:)`. Use a printable custom
  annotation whose appearance stream fills the committed variable-width vector
  contours. Raster appearance data is prohibited.
- Export text as annotations. Prefer native free-text where it satisfies
  CoreText-shaped LTR/RTL, fallback fonts, selection, copying, and viewer
  interoperability. Otherwise validate a custom vector-appearance annotation
  that retains the Unicode string in `contents`.
- All module annotations display and print. Text combines the general PDF
  `Locked` and `LockedContents` flags. Signatures combine `ReadOnly`, `Locked`,
  and `LockedContents`; do not substitute the widget-only `isReadOnly` property.

## Fixture workflow

1. Exercise the same PDFKit, Quartz, and CoreText operations intended for
   production on macOS.
2. Cover PDF-only, image-only, and mixed creation; append, remove, and reorder;
   mixed sizes; non-zero box origins; rotations; and write/reopen.
3. Cover Unicode, Arabic and Hebrew bidi text, fallback fonts, selection and
   copying, and refusal by supported ordinary viewers to move or edit locked
   text.
4. Verify signature bounds, page association, display/print flags, read-only and
   lock flags, and a persisted vector-only appearance stream. Supported ordinary
   viewers must not edit, move, resize, or replace it.
5. Verify visible output and editing behavior in the supported viewer corpus.
6. Convert required behavior into focused assertions. Do not inspect or reject
   unsupported advanced PDF semantics, and do not add PDFium fallback.

## Completion

- Direct import, geometry, annotation persistence, locked-but-copyable text,
  read-only vector signatures, write/reopen, and supported viewer
  interoperability are proven.
- Tasks 6, 6d, and 6g have no unresolved ownership or representation decision.

Status: In progress — the local Hebrew visual-review fixture is not bundled and
its test is skipped when absent. RTL/fallback-font rendering and selection or
copying interoperability still require macOS fixture and supported-viewer
evidence. A skipped fixture is not completion evidence; external-viewer checks
remain pending. A one-off rendering measurement may inform
integration tuning, but platform API performance is not a migration gate.
