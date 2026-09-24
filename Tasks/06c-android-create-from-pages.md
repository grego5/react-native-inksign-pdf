# Task 06c: Create documents through addPages on Android

Back to task index: [TASKS.md](../TASKS.md)

## Depends on

- [Task 05](05-integrate-android-mutable-pages.md) and [Task 06b](06b-create-pdf-from-pages.md)

## Objective

Make Android `addPages` create a document from selected PDF and image inputs when the coordinator has no document, while preserving its existing append transaction.

## Implementation

1. Update `HybridInkSignView.addPages`, `MutableDocumentCoordinator`, and the page-input boundary to admit creation without `hasDocument`. Stage first, resolve image page size from the option, active page, or A4, then commit active text only when an actual append to an existing document will proceed.
2. Use the shared `CREATE` assembler command for an empty coordinator and `APPEND` for an existing document. Validate and open the candidate on `PdfSessionWorker`, then publish its working file, stable page records, active first-added page, generation, and dirty state as one coordinator transition. Keep render and export sources pointed at the published candidate.
3. Resolve empty selection according to Task 06a without creating a file or changing callbacks. Reject failed input or assembly without publishing a partial document; retire staged and candidate artifacts. Keep `removePage`, `movePage`, and `finalize` unavailable until creation succeeds.

## Completion

- Focused JVM and connected tests cover image-only creation with A4 and custom size, PDF-only creation, mixed ordering, cancellation on an empty view, failure cleanup, page history after creation, and final export. The image-only connected check must reopen the saved candidate and verify rendered pixels as well as requested page dimensions. Run the Android runner and `git diff --check -- ':!nitrogen/generated/**'`.

Status: Complete — focused creation checks and the full connected Android suite
pass. The image-only check reopens the saved candidate and verifies visible
pixels and requested dimensions; the JVM suite and Android build also pass.
