# 04 - Replace structural PDFKit writing

[Plan](../TASKS.md)

Status: Completed (static); runtime acceptance deferred
Complexity: High
Depends on: 02, 03

## Objective and non-goals

Create detached working candidates with the shared assembler, then install them
through the existing coordinator and PDFKit presentation. Preserve queues,
interaction ownership, and committed history.

## Read before editing

- `ios/MutableDocumentTransactions.swift`: `StructuralInput`, `assembleCandidate`.
- `ios/InkSignDocumentState.swift`: page order, artifact registration, publication,
  rollback, and page state.
- `ios/DocumentCandidateLoader.swift`: loading and rebinding.
- `ios/InkSignView+Document.swift`: candidate installation.
- `ios/ViewerInteractionCoordinator.swift`: structural readiness entry points.
- `core/pdfium-adapter/PdfiumPageAssembler.hpp` and `.cpp`: `assemble`.
- Maintainer `swift-ios/view-lifecycle.md` and shared document-operation contract.

## Current contract

Assembly currently writes a detached PDFDocument. Publication retains stable IDs,
content/history, targets, orientation, and selection. Stale or failed candidates
leave published state intact. Completion waits for presentation readiness.

## Implementation

1. Convert Swift commands to shared `Create`, `Append`, `Remove`, and `Move`.
   Read the working file on the PDF queue; never serialize the live PDFView
   document to obtain input bytes.
2. Feed images from Task 03 and write to a registered candidate. Prepare analysis
   for imported pages from that PDFium candidate before publication, per Task 02.
3. Keep UUID allocation, page order, and activePage policy in Swift. Rebind
   surviving IDs/history/targets/analysis to output order; allocate IDs only for
   new pages. Image source analysis is empty.
4. Validate assembler metadata and reopen with PDFKit. Compare raw stored file
   geometry before applying pending coordinator rotation. Then rebind and apply
   current orientation for presentation. Structural writing does not incidentally
   bake pending rotations into content or overwrite saved text layout.
5. Publish through the existing operation token and main-thread commit. Preserve
   page/state callbacks, dirty rules, latest interaction policy, and single promise
   settlement after page/overlay/transform/viewport readiness.
6. Retain running worker resources until completion after cancellation. Delete
   unclaimed candidates and retired working files through existing artifact rules.
   Remove structural PDFKit insert/remove/write serialization once callers migrate.
7. This phase still uses the existing viewer coordinator. Task 09 removes framework
   page objects and active selection from its data model; Task 12 moves PDFKit
   reopening/readiness exclusively into presentation. Do not add a second core
   or permanent view callback interface to preserve this intermediate design.

## Static validation and completion

- Trace empty creation, append with an inactive target, remove, reorder,
  replacement during work, and pre-publication failure.
- PDFKit owns displayed page objects; the coordinator owns stable IDs. No new
  persistent native document, worker queue, or state coordinator is introduced.
- Run `git diff --check`.
- Proposed commit: `feat(ios): assemble working documents through PDFium`.

## Implementation result

- Detached append/create/remove/reorder now use the shared assembler. Native
  metadata is checked against the PDFKit reopen before installation.
- Surviving pages rebind stable IDs/history/targets/orientation and source
  analysis; only newly imported candidate pages are analyzed. activePage policy
  and registered-artifact failure cleanup stay in the current coordinator.
- Existing precision tolerance is retained for metadata comparison. No tests
  or builds ran; source annotation/box interoperability remains a Task 08 gate.
