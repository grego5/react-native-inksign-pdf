# 02 - Import canonical PDFium analysis

[Plan](../TASKS.md)

Status: Completed (static); fixture migration/runtime acceptance deferred
Complexity: High
Depends on: 01

## Objective and non-goals

Use PDFium for immutable working-page text and rule analysis, retaining the Swift
prepared-target resolver. Preserve query matching, target identity, and Android's
existing analysis orientation.

## Read before editing

- `core/pdfium-adapter/PdfiumDocumentSession.cpp`: analysis cache,
  `inspectHorizontalSnapCandidates`, `preparePageAnalysis`, `FPDF_PageToDevice`.
- Task 01's `ios/PdfiumBackend.h` and `.mm`.
- `ios/PageAnalysis.swift`: `build`, `prepareLabels`, `lookup`, embedded values,
  and `displayedFieldGeometry`.
- `ios/DocumentCandidateLoader.swift`: `load`, `pageState`, `rebinding`.
- `ios/InkSignView+Document.swift`, `MutableDocumentTransactions.swift`, and
  `InkSignDocumentState.swift`: import paths and `sourceAnalysis` ownership.
- Maintainer `swift-ios/view-lifecycle.md` and geometry contracts in
  `references/architecture.md`.

## Current contract

iOS currently analyzes source pages using PDFKit. The latest shared PDFium
implementation already cancels intrinsic rotation and retains canonical rule
segments before display filtering. Reuse it; Swift's old builder applies a
PDFKit-specific display-to-canonical conversion that must not apply to this input.

## Implementation

1. Reuse `preparePageAnalysis` and its canonical snapshot. Retain source metadata,
   including intrinsic rotation; no additional mode/cache/session is required.
2. Preserve shared normalization before classification/grouping and orthogonal
   rule endpoints before display filtering. Do not mutate native rotation or
   reimplement the existing canonical conversion in Swift.
3. Bridge scalars, nullable glyph bounds, row extents, and rule endpoints/indexes.
   Build an explicit scalar-to-UTF-16 map. Missing geometry, surrogate pairs, and
   replacement characters retain aligned source ranges; do not drop characters
   and shift later identities.
4. Replace PDFKit extraction in `InkSignPdfPageAnalysis.build` with a snapshot
   factory. Reuse complete-label grouping, joined matching, repeated-word counts,
   case policy, and value detection. Canonical input must not pass through the
   old display-to-canonical conversion.
5. Analyze published working bytes on open and assembled candidate bytes for new
   imported pages, before publication. Reuse one session for the affected pages.
   Pass snapshots explicitly to candidate loading. Unchanged carried source
   pages retain their stable-ID snapshots; images have empty source analysis.
   A genuine source replacement retires affected analysis/targets. Extraction
   failure rejects import rather than masquerading as successful empty analysis.
   Do not retain originals as an alternate analysis document after rewriting.
6. Preserve source-range/rule identity through navigation, reorder, and rotation.
   Project at the existing displayed-query boundary. Remove production PDFKit
   text-selection and Core Graphics scanner dependencies; retain rule value and
   selection utilities with callers. Snapshots retain no PDF bytes or handles.

## Static validation and completion

- Trace intrinsic rotation followed by user rotation: normalize once, project once.
- Trace candidate imports and rebinds: analysis reflects authoritative source
  content while unchanged surviving pages do not require repeated extraction.
- Run `git diff --check`; fixture adaptation belongs to Task 08.
- Proposed commit: `feat(ios): prepare canonical source analysis with PDFium`.

## Implementation result

- PageAnalysis builds canonical labels/values from the existing shared snapshot;
  UTF-16 source ranges preserve absent bounds and supplementary characters.
- Candidate loading analyzes only missing source pages through one temporary
  session and retains unchanged page snapshots by candidate position.
- PDFKit extraction/conversion is removed from production analysis. Native
  text-page failure rejects extraction and RAII closes text pages on all exits.
- Old fixture builder calls require Task 08 migration. No tests/builds ran.
