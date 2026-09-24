# Task 05a: Establish iOS coordinator ownership

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Move the existing iOS document and page state behind one mutable-document coordinator while preserving current open, navigation, editing, and export behavior. This task establishes the ownership boundary needed by Task 6; it does not add structural page commands.

## Implementation

1. Replace `InkSignPdfDocumentState` and index-owned `InkSignPdfPageState` in `ios/DocumentState.swift` with one coordinator-owned ordered page collection. Give each page a stable native ID, geometry, PDFKit page, and existing ink/text history. Derive indexes from collection position; store the active page by ID.
2. Keep the live PDFKit document and document generation in the coordinator. Keep `InkSignView` as the Nitro and UIKit adapter and `InkPdfView` as presentation; the coordinator serializes native document work.
3. Update open, navigation, history, text, overlay installation, callbacks, and disposal to read or request changes through the coordinator. Remove parallel page and generation state from the view rather than adding compatibility mirrors.
4. During open, copy the caller-owned PDF to an exact module-owned working artifact before publishing. Use that artifact as the live rendering and export source; release it on replacement and disposal. Preserve caller-file read-only behavior and existing open readiness.

## Regression expectations

- Page switches restore the correct page-local ink/text history, and delayed input or render callbacks cannot apply to another page or generation.
- An invalid or superseded open leaves no published partial document or leaked working artifact. Existing open, navigation, undo/redo, dirty-state, and export results remain valid.

## Completion

- Add focused lifecycle and page-state tests for stable IDs, active-page lookup, working-file ownership, replacement, and stale-result suppression.
- Update the iOS lifecycle reference to match implemented ownership. Run focused iOS lifecycle validation and `git diff --check -- ':!nitrogen/generated/**'`.

Status: Complete

Coordinator ownership, stable page IDs, and exact working-PDF artifact
ownership are implemented. Focused lifecycle coverage verifies the ownership
boundary.
