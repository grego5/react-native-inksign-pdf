# iOS canonical targets and displayed operations
[Plan](../TASKS.md)

Status: Planned
Complexity: High

## Objective and scope
Apply the same ownership and coordinate contract as Task 01 on iOS. Keep PDFKit coordinate conventions at the adapter boundary. Public methods and user-facing behavior remain unchanged.

## Read before editing
Lookup map: ios/Geometry.swift (PageGeometry); ios/DocumentState.swift (InkSignPdfTextTarget, reserve/adopt/update); ios/PageAnalysis.swift (build, displayedFieldGeometry, label sourceRanges); ios/TextCommands.swift (resolve/value/options/focus); ios/TextState.swift; ios/TextInteraction.swift; ios/TextRendering.swift.
References: architecture.md, swift-ios/viewport-input.md and swift-ios/view-lifecycle.md under .agents/skills/inksign-pdf-docs/references/.

## Preserved invariants
Task 01's ownership, lifetime, value precedence, rotation and rule-eligibility contracts apply. Existing local text wrapping and marked-text admission remain native. PDF media-box origins and intrinsic rotation are supported.

## Implementation sequence
1. Use canonical media-box-relative top-left geometry at rotation zero; keep degree-based rotation inside PageGeometry. Convert PDFKit's coordinates, including nonzero media-box origins, at analysis/export boundaries.
2. Normalize prepared glyphs and rules into canonical space once. Retain exact label sourceRanges and original rule identity rather than reconstructing identity from the index of a filtered displayed rule array.
3. Replace target layoutGeometry-dependent placement storage with canonical placement, writing rule, and detection geometry. Route reserve/adopt/reuse through one coordinator policy. Remove unprojected bounds deduplication against caller display bounds.
4. Project candidates into display for region, direction and occurrence selection. Preserve complete-label token frequencies and existing eligible-rule tie-breaking. Detect embedded text using the local rule-width/label-height band on the chosen side; free targets use supplied placement bounds. Adopt only intersecting projected module text and reject competing annotations.
5. Keep committed annotations' local layout and layout-to-canonical transform. Derive display geometry for rendering, selection, editor activation and drag. Convert accepted manual placement into canonical target geometry once; keep named source association distinct from editable text placement.
6. Reuse target IDs through rotation/navigation/reordering. Resolve preserves formatting. Focus derives from the stored rule or free center and preserves request supersession, zoom, offset, viewport anchoring and optional ink-mode activation.
7. In setPreparedTextOptions, construct final formatting first, then recompute visible bounds using that formatting. Selection and hit testing must use the resulting displayed geometry.
8. Remove superseded projection/state synchronization paths once all callers use the shared mapper.

## Ownership and execution
Coordinator and overlays retain their current main-thread ownership. Analysis stays immutable after preparation. Page rotation changes presentation metadata, not saved target geometry or annotation layout. No generated-interface change is expected.

## Completion
iOS follows the same physical identity and displayed-operation semantics as Android. Record any platform mapping uncertainty for final verification.
Proposed commit: Refactor iOS text targets to canonical geometry

