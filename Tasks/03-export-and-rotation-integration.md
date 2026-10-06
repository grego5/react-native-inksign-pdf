# Integrate canonical geometry with rotation and export
[Plan](../TASKS.md)

Status: Implemented; verification deferred to Task 05
Complexity: High

## Objective and scope
Complete Tasks 01–02 through render/export boundaries without applying rotation twice. Preserve source PDF content and existing vector/text export. Pager tuning and the preview-failure finding are separate work.

## Read before editing
Android: PdfExport.kt, PdfiumNativePdfExporter.kt, PdfiumPageAssembler.kt, TextLayout.kt and DocumentCoordinator.kt under android/src/main/java/com/margelo/nitro/inksignpdf/.
Native: core/pdfium-adapter/PdfiumDocumentSession.cpp/.hpp; android/src/main/cpp/pdfium_render_jni.cpp.
iOS: ios/NativePDFExporter.swift, ios/InkSignView+Export.swift, ios/Geometry.swift and ios/TextRendering.swift.
References: android/export.md and swift-ios/export.md under .agents/skills/inksign-pdf-docs/references/.

## Preserved invariants
Source content and source files remain unchanged. Finalize snapshots committed content and publishes a separate output after freshness validation. Current page orientation is persisted structurally; annotation history and local wrapping are retained.

## Implementation sequence
1. Trace each platform's local text layout → canonical content → PDF output mapping. Reuse the existing mapper rather than adding export-specific inverse rotations.
2. Snapshot canonical target/content geometry and annotation local-layout transforms. Snapshot current page rotation once with document/page identity.
3. Keep shaping and line selection in local layout space. Transform positioned runs into canonical PDF content at export, then apply the captured page rotation as page metadata/output orientation exactly once.
4. Verify source PDFs with initial rotation and nonzero media-box origins have one source-adapter conversion and one output conversion. Preserve ink's existing canonical-content mapping.
5. Rotation must not rewrite target identities, canonical rectangles, annotation layout, or history snapshots. Cancel/settle live gestures through existing lifecycle rules before changing presentation.
6. Remove obsolete rotation synchronization and per-path mapping code. Retain cached analysis across presentation rotation where its canonical source content is unchanged; invalidate only presentation-dependent data.

## Ownership and execution
Worker export consumes immutable snapshots. Check session/operation freshness on publication. Generated files remain generator-owned; regenerate only if a demonstrated interface change is necessary.

## Completion
Preview, editor geometry, and export consume the same local-layout-to-canonical mapping. All remaining rotation mutation sites concern page presentation or structural output only.
Proposed commit: Align rotation and export with canonical text geometry
