# Task 06: Integrate mutable pages through the native iOS backend

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Implement iOS `addPages`, `removePage`, and `movePage` with one coordinator-owned
`PDFDocument`, stable page identity, and transactional candidate publication.
Do not call PDFium from the completed iOS path.

## Depends on

- [Task 04](04-add-ios-file-picker.md)
- [Task 05b](05b-centralize-ios-operations.md)
- [Task 06f](06f-validate-native-ios-pdf-backend.md)

## Architecture

- `PDFDocument` is the sole published PDF page model. Swift page records own a
  stable ID, PDFKit page reference, PDFKit-derived geometry, and page-local
  history. Index is derived from ordered collection position.
- Every structural command prepares a detached `PDFDocument`, writes it to a
  candidate URL, reopens and validates it, reconstructs the ordered page
  records, and publishes the complete replacement in one coordinator
  transition.
- Direct cross-document `PDFPage` insertion is the default import mechanism.
  Do not transfer pages through `PDFPage.dataRepresentation()`. Preserve page
  order, visible content, supported boxes, and rotation; advanced source
  relationships are outside this task's contract.
- PDFKit document work is serialized off live presentation state. UIKit view
  installation and callbacks remain on the main actor.

## Implementation

1. Admit picker staging and structural commands through the existing serialized
   coordinator boundary. Commit active text editing and reject an incomplete
   ink gesture before snapshotting command inputs.
2. Normalize images off the main actor with corrected orientation, white
   background, aspect-fit placement, a 200-DPI cap, and JPEG quality 0.72 only
   when re-encoding is required. Create `PDFPage` image pages at the resolved
   PDF point size.
3. Append every selected PDF page in source order through direct page insertion.
   Preserve mixed source ordering and activate the first added page.
4. Remove the current stable page ID, rejecting removal of the only page.
   Select the page now occupying its index, or the preceding page when the
   removed page was last.
5. Move the current page by removing and reinserting it at the validated
   destination. A same-index move succeeds without publishing a new document.
6. Carry surviving page history by stable identity. Create history only for new
   pages and discard it only for removed pages.
7. Write, reopen, and validate the detached candidate before publication.
   Validate count, order, required boxes, rotation, visible content, and
   module-owned annotations. Do not inspect or reject explicitly unsupported
   advanced PDF semantics. Do not implement partial mutation followed by
   rollback.

## Regression expectations

- The caller's source and the published working PDF are never modified in
  place.
- Failed, cancelled, and stale work leaves the current document, active page,
  histories, generation, and presentation unchanged.
- Structural dirty state remains independent of page-local undo and redo.
- Do not add PDFium fallback, dual session state, or guessed recovery behavior.

## Completion

- Focused XCTest covers cross-document append, image pages, mixed ordering,
  removal selection, movement, same-index no-op, stable history, geometry,
  failed candidate isolation, cancellation, and cleanup.
- The mutable-page path contains no PDFium call or session dependency.

Status: Implementation updated; native macOS validation is pending.
