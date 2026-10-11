# 05 — Implement iOS headless document operations

[Plan index](../TASKS.md)

Status: Planned
Complexity: High
Dependencies: 03

## Objective and non-goals

Implement iOS headless factory/document/page handles using shared PDF services, with deterministic teardown and exports surviving close. Do not construct PDFView or implement fonts here.

## Read before editing

- Task 01 spec and task 03's shared document/text owner.
- `ios/DocumentCandidateLoader.swift`, `MutableDocumentTransactions.swift`, `PageInputCoordinator.swift`: source staging, image conversion, candidate publication.
- `ios/DocumentState.swift`: allocateExportArtifacts, publishOutput, discardArtifact, closeDocument, dispose and pdfQueue.
- `ios/InkSignView+Export.swift`: captureExportSnapshot, writePDF, publication/settlement; `NativePDFExporter.swift`.
- Maintainer architecture, Swift lifecycle/export/configuration-validation references; native-module and Swift implementation skills.
- InkSignViewLifecycleTests, SignatureExportTests, MutablePageImageEncoderTests.

## Current behavior to preserve

Page source analysis is captured before working-copy serialization. PDFKit/Quartz preserve visible supported page content. Current disposal asynchronously deletes artifacts on pdfQueue; headless close must await this cleanup. Published outputs currently enter ownedOutputs.

## Implementation steps

1. Implement `ios/HybridInkSignDocumentFactory.swift`, `HybridInkSignDocument.swift`, and `HybridDocumentPage.swift`. Create an independent owner, load source with analysis/metadata, and resolve the factory only after native document readiness. Failure releases the candidate and owner.
2. Reuse explicit-source staging and image encoding for PDF/supported images; default A4/image import settings apply. Bypass controller/picker/readiness branches and create no PDFView, view overlays, or ink canvas.
3. Implement indexed append/remove/move/rotation through shared detached transactions. Bind indexes on execution; retain stable surviving page IDs/analysis/content; reject sole-page removal; failed candidates leave current content intact.
4. Expose synchronous owner-thread pageCount and live PageInfo on stable page handles. getPage(index) uses FIFO preparation; all text calls delegate to the shared service.
5. Export immutable committed snapshots through NativePDFExporter. Add explicit output-transfer policy so headless success removes output from owned deletion sets before resolving. Keep the existing viewer policy.
6. Mark the document closing on invocation, reject subsequent work, drain already-admitted async commands, invalidate handles, and await a serial-PDF-queue cleanup barrier plus artifact deletion before resolving. Repeated close shares one completion; avoid main-thread queue deadlocks.
7. Clear PDFDocument/PDFPage, analysis, target/content, and worker snapshot ownership after users finish. Disposal cleans up safely if callers omitted close.
8. Delete only owned staged/working/scratch/unpublished files. Preserve successful returned outputs and caller input files.

## Ownership, threading, and geometry

State mutations/handle checks remain on the main thread; PDF IO/export stays on pdfQueue. No live PDFKit view object crosses into workers. Handle metadata follows stable page IDs and current display geometry. Preserve supported media boxes, source rotation, and captured text layout transforms.

## Tests and expected results

Add InkSignDocumentTests: headless PDF/JPEG/PNG import; named Hebrew field/free-bound edits; append/move/rotate/remove; failed import leaves prior text/pages intact; removed/closed handles reject. Reopen repeated exports and verify visible annotations/signatures/order plus unchanged source bytes. Keep a page handle referenced during close and assert owner resources are released. Controlled PDF work demonstrates close drains and outputs remain readable.

## Validation and completion

On a hash-verified Mac checkout run `bash ./tools/test-ios-mac-vm.sh` with IOS_TEST_ONLY selecting InkSignDocumentTests, then affected lifecycle/export classes. Until task 09, record incomplete font integrations. Report unavailable Mac/runtime validation explicitly. Complete when headless operations and cleanup/output ownership assertions pass without constructing presentation.

Proposed commit: `feat(ios): add headless document operations`
