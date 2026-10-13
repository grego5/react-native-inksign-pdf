# 15 - Share prepared rotation projections and pairing

[Plan](../TASKS.md)

Status: Planned
Complexity: High
Depends on: 02, 09-13

## Objective and non-goals

Give prepared lookup and manual placement one core-owned projection of retained
canonical source analysis, matching Android. Preserve target identity and the
shared cache lifetime fix. No OCR, upright-orientation inference, general angled
text resolver, PDFKit rescan, or separate viewer analysis cache is added.

## Read before editing

- Android `PreparedDocumentPage.kt`: PreparedPageContext.projected and
  ProjectedPreparedPage.selectPair; `DocumentTextCommands.kt`: resolve;
  `TextKeyPlacement.kt`: ordering, direction, and rule-fit policy.
- `ios/PageAnalysis.swift`: canonical snapshot factory, prepared labels,
  displayedFieldGeometry; `TextCommands.swift`: InkSignPdfKeyRuleSelector and
  resolvePreparedText; core prepared contexts introduced by Tasks 09-11.
- `ios/InkSignView+PlacementRules.swift`: schedulePlacementRuleScan;
  `TextInteraction.swift` and PageGeometry utilities: placement installation,
  geometry validity, canonical/display transforms. Locate exact consumers with rg.
- `core/pdfium-adapter/PdfiumDocumentSession.cpp`: preparePageAnalysis and
  trimPageAnalyses; `ios/PdfiumBackend.h` and `.mm`: owned analysis transfer.
- Android saved-rotation one-rule cases in PageRotationInstrumentationTest,
  projection cases in PreparedTextResolverTest, and the oversized-page regression
  in PdfiumSmokeInstrumentationTest; iOS PlacementRuleDetectorTests and
  InkSignViewLifecycleTests; lifecycle/coordinate maintainer references.

## Current contract

Task 02 imports canonical glyph rows and horizontal/vertical rule endpoints from
PDFium. Swift's current projection computes line height from the projected y
delta, which becomes zero at a quarter turn, and rebuilds geometry per query.
Android retains source identity and caches projections and label/rule pairing.
The shared native code now copies a prepared snapshot before trimming its LRU.

## Implementation

1. Retain canonical analysis once per stable page in the existing core prepared
   owner. Add displayed projections keyed by the four current page rotations.
   Keep caches out of view adapters and immutable snapshot value copies. Retire
   them with page/source replacement or core cleanup; preserve them on reorder.
2. Project labels and all retained rule endpoints using current geometry exactly
   once. Preserve source ranges and canonical rule sourceIndex. Keep horizontal
   rules in displayed coordinates for pairing and snapping. Carry projected row
   endpoints and use their Euclidean length for label line height, preserving a
   positive value at 90/270 degrees instead of abs(deltaY).
3. Apply existing complete-label matching and optional displayed search-region
   filtering, then first/last order by displayed top/left/source index. Cache
   pairing success and failure by canonical label identity and effective
   direction within each rotation. Do not key caches by arbitrary query strings
   or store option-specific formatting/annotations in the pairing result.
4. Keep target identity based on canonical label ranges plus selected canonical
   rule identity. Re-resolving the same pair preserves its ID. Choosing another
   physical rule after rotation/direction may legitimately produce another ID.
   Existing annotations retain their captured layout and remain editable.
5. Make manual placement consume the same core-owned projected labels/rules.
   Keep request authorization and editor installation in the viewer; install
   only for the captured page/current geometry/request. Pure projection needs
   no worker scan, PDFKit extraction, or extra document FIFO.
6. Preserve the shared snapshot-before-trim implementation. The native eight-page/
   8 MiB LRU limits caching, not supported prepared-page size. Swift bridge and
   core snapshots must own their data after native eviction/session closure.
   Do not pin oversized entries indefinitely or add an iOS limit workaround.

## Ownership and regression expectations

Core caches and synchronous queries remain owner-executor confined; native
extraction remains serial-worker owned. Saved /Rotate is normalized by PDFium;
current page rotation is applied at projection. Do not infer intended upright
orientation from glyphs or camera content.

Reuse a one-label/one-rule PDF saved at 0/90/180/270. Sideways rules reject with
text_rule_not_found rather than losing the label; rotating back upright succeeds
without extraction and keeps the same pair's ID. Use direction explicitly for
the 180-degree same-pair case. Cover current horizontal vertical-source guides,
positive projected line heights, projection/pair cache reuse, and export/reopen.
Add one iOS bridge case exceeding the native budget: snapshot and a subsequent
request succeed, and retained Swift data remains valid after eviction/close.
Reuse the native regression instead of reproducing its cache implementation.

## Validation and completion

- Static trace normalize once -> core projection -> lookup or viewer snapping;
  confirm source ranges/endpoints survive bridge conversion and cache retirement.
- Run `git diff --check`. Execution remains prohibited. With explicit approval,
  run focused Mac rotation/analysis/headless cases and inspect exported rendering;
  report unavailable host/device and keep static versus runtime results separate.
- Complete when lookup/snapping share projected source geometry, identities are
  stable for the same pair, and cache pressure cannot reject valid preparation.
- Proposed commit: `fix(ios): align prepared rotation and analysis lifetime`.
