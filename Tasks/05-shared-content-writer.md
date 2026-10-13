# 05 - Extract the shared content writer

[Plan](../TASKS.md)

Status: Completed (static); Android export regression/runtime acceptance deferred
Complexity: High
Depends on: 01

## Objective and non-goals

Extract Android's production exporter into a reusable writer, preserving Android
output behavior. Do not base iOS export on the older shared bitmap exporter.

## Read before editing

- `android/src/main/cpp/pdfium_export_jni.cpp`: shaping, CID/Unicode mapping,
  paths, transforms, save/reopen validation, and JNI conversion.
- `android/src/main/cpp/pdfium_harfbuzz_api.h`: shaping declarations.
- Android `PdfExport.kt`, `PdfiumNativePdfExporter.kt`, and `CMakeLists.txt`.
- `core/pdfium-adapter/PdfiumSignedDocumentExporter.*`: obsolete exporter.
- `core/pdfium-adapter/PdfiumLibraryInternal.hpp`: shared locking.
- Maintainer `android/export.md`; apply the C++ implementation skill when coding.

## Current contract

Android resolves line runs/fonts, shapes with HarfBuzz, and embeds text/vector
paths. Export preserves multi-unit Unicode mappings, logical-line marks, font
subsetting behavior, and validated output. Most writer code currently uses JNI
types inside a platform translation unit.

## Implementation

1. Add `core/pdfium-adapter/PdfiumContentWriter.hpp` and `.cpp` with typed, owned
   page, font, positioned-glyph/cluster, and filled-path inputs. Use fixed-width
   C++ types. Preserve full logical UTF-16 lines, cluster mappings, colors,
   direction, layout transforms, clipping contracts, and expected geometry.
2. Separate existing Android HarfBuzz shaping from serialization. Keep its run
   ordering and shaping algorithm in an Android adapter producing the common
   positioned model. iOS supplies CoreText positions without reshaping.
3. Move CID allocation, glyph-to-Unicode mapping, font loading/subsetting,
   ActualText/base-direction marks, paths, page rotation, save/reopen checks, and
   subset-save fallback to the common writer. Preserve current errors and
   fallback behavior; introduce no new font selection or re-layout policy.
4. JNI converts admitted arrays, invokes shaping/writing, and translates errors.
   Retain its external signature and destination artifact contract. Update CMake
   and pod source lists without linking Android-only sources on iOS.
5. Keep PDFium resources and borrowed spans inside the synchronous write and
   shared API lock. Platform snapshots own bytes until the operation returns.
6. The old bitmap exporter remains only for its legacy smoke caller until
   Task 08 migrates that caller and removes the obsolete implementation.

## Static validation and completion

- Compare moved code against the original shaping/mapping/subset retry and
  geometry paths. Do not fold unrelated optimizations into this extraction.
- Common code has no platform UI/JNI dependencies; public/generated interfaces
  remain unchanged.
- Run `git diff --check`.
- Proposed commit: `refactor(pdfium): share vector content export across platforms`.

## Implementation result

- PdfiumContentWriter owns compact platform-free buffers, font/CID/Unicode maps,
  logical-line marks, contours, source transforms, rotation, save/subset retry,
  and reopened validation. It owns the shared library lease/API lock.
- Android JNI marshals owned buffers and writes the result. The separate Android
  shaper preserves HarfBuzz cluster handling; CoreText can supply prepositioned
  glyphs through the same shaping boundary without linking HarfBuzz on iOS.
- Per-path colors support PencilKit while Android retains its uniform default.
  The obsolete exporter remains only for the planned smoke-caller migration.
- No tests/builds ran. Common/Android linkage and output parity remain unverified.
