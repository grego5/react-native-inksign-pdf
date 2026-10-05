# Android canonical targets and displayed operations
[Plan](../TASKS.md)

Status: Planned
Complexity: High

## Objective and scope
Make Android target identity and persistent placement geometry independent of rotation. Keep placement, editing, and focus calculations in displayed coordinates. Public API, pager gestures, transition animation, and rule eligibility retain their contracts.

## Read before editing
Lookup map: PageCoordinates.kt (raw/display/layout transforms); DocumentCoordinator.kt (TextTargetSlot, reserveTextTarget, adoptTextTarget, updateTextTargetBounds); HybridInkSignView.kt (resolvePreparedText, displayedTargetBounds, requireHorizontalRule, setPreparedTextOptions, focus); PreparedTextResolver.kt; TextInteractionOverlay.kt (draft creation, commit, dragging); TextLayout.kt (TextAnnotation, rendering). Paths are under android/src/main/java/com/margelo/nitro/inksignpdf/.
References: .agents/skills/inksign-pdf-docs/references/architecture.md#document-state, android/viewport-input.md, android/view-lifecycle.md.

## Preserved invariants
Coordinator owns target IDs and committed history; overlay owns drafts, selection, and IME state. Captured page handles survive navigation/reordering. Document replacement, disposal, and page deletion invalidate them. Rotation preserves committed text identity, wrapping, and history; rotation itself has no annotation history entry.
Value precedence remains draft, committed module text, embedded text, empty.

## Implementation sequence
1. Use canonical media-box-relative top-left coordinates at rotation zero. Android rotation remains quarter-turn units. Extend PageCoordinates only where needed; use explicit canonical/display/layout names at boundaries instead of a generic coordinate framework.
2. Canonicalize prepared source glyphs and rule endpoints once when acquiring analysis, accounting for the source PDF's initial rotation. Keep source label ranges and source rule identity stable. Preserve exact word ranges when a visual label spans noncontiguous source text; build bounds/exclusions from those ranges.
3. Replace TextTargetSlot's captured displayed placement metadata with canonical placement bounds and canonical writing-rule endpoints. Keep writing rule, placement/flow region, and embedded-value detection region distinct. Store no mutable displayed copy.
4. Convert incoming free bounds from current display into canonical space before deduplication. Make the coordinator the single authority for target reuse; remove raw-bounds deduplication that competes with projected resolver comparisons. Equal physical targets reuse IDs; equal numbers in different orientations need not identify the same target.
5. For named resolution, project source candidates into current display, perform existing direction/occurrence/region selection there, then identify the selected target by source ranges and source rule. Project the local detection band for embedded extraction and annotation adoption. Exclude only selected label glyphs.
6. Keep text layout local: saved layout bounds, flow bounds, and orientation define wrapping, with one layout-to-canonical transform. Derive layout-to-display through PageCoordinates. New insertion captures current display layout; rotation leaves that layout unchanged. Canonical bounds derived from local layout are not a second independently mutable owner.
7. On manual creation/drag/commit, convert accepted placement back into canonical target geometry once. Update the target through coordinator methods. Named associations keep their source identity and writing rule; free targets track their accepted placement. Keep embedded fallback consistent with the target's authoritative detection region when placement changes.
8. Derive displayed target geometry for entries, focus, and new insertion. Named focus uses the writing rule; free focus uses center. A currently vertical rule rejects new field creation/focus without mutation; existing text remains readable, editable, and clearable. Re-resolution preserves formatting.
9. Apply all formatting changes before computing visible layout bounds once. Keep active-draft admission and composing behavior on their existing path.

## Ownership and execution
Native document/view changes run on the UI thread; asynchronous analysis publishes only into its captured valid document/page. Rotation changes page presentation metadata and dependent presentation caches, not target geometry. No binding changes are expected.

## Completion
All Android target reuse, adoption, manual placement, editing, focus, and committed rendering follow the explicit spaces above. Remove superseded conversion branches in the same change. Record static limitations; execution validation belongs to the final task.
Proposed commit: Refactor Android text targets to canonical geometry

