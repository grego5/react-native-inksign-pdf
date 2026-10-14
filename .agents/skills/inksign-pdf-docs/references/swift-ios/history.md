# History and callbacks

- Core page history owns permanent base content and keyed tracked overrides.
  Undo/redo apply affected text IDs/drawing only, preserving independent base
  edits. Text retains captured layout orientation; ink uses canonical geometry.
- Viewer cores record history; headless cores retain edits in base content.
  Programmatic `untracked: true` uses base content unless the identity has
  retained tracked history, including deleted targets and redo-only actions.
- Page dirty equals `canUndo`; redo-only history is clean. Structural changes
  additionally dirty the document. Content flags exclude drafts/imported content.
- Live ink, editor drafts, selection, and predictions belong to presentation.
  Finished strokes and text edits use explicit core page commands. Undo/redo/clear
  settle transient input first. Stale drawing baselines reject conflicting commits.
- `clearInk()` cancels live ink, then records one drawing change, preserving text
  and source PDF content. Empty ink is a no-op. `clear()` groups module content.
- Core changes refresh active committed presentation; other pages retain their
  content without rebuilding the current overlay. Delayed ink cannot change page.
- State/page callbacks run on the main thread and deduplicate payloads. Shapes:
  [state contracts](../architecture.md#state-inspection-and-events).
- Export reads committed snapshots without changing history or live input.
  Disposal releases callbacks and prevents late viewer publication.
