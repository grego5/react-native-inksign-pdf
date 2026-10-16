# History and callbacks

- Core page history owns permanent base content and keyed tracked overrides.
  Undo/redo apply affected text IDs/drawing only, preserving independent base
  edits. Text retains captured layout orientation; ink uses canonical geometry.
- `recordHistory` is fixed at document creation (default true). Attachment does
  not change it; disabled recording retains edits in base content.
  Programmatic `untracked: true` uses base content unless the identity has
  retained tracked history, including deleted targets and redo-only actions.
- Page dirty includes recorded undo entries or a changed tracked text transaction;
  redo-only history is clean. Structural changes additionally dirty the document.
  Content flags include current admitted text and exclude imported PDF content.
- Live ink, caret/composition, selection, and predictions belong to presentation.
  Finished strokes and text edits use explicit core page commands. Undo/redo/clear
  validate the page handle before settling transient input. Deleted-page commands
  preserve another page's active draft. Stale drawing baselines reject conflicting commits.
- `clearInk()` cancels live ink, then records one drawing change, preserving text
  and source PDF content. Empty ink is a no-op. `clear()` groups module content.
- Core changes refresh active committed presentation; other pages retain their
  content without rebuilding the current overlay. Delayed ink cannot change page.
- State/page callbacks run on the main thread and deduplicate payloads. Shapes:
  [state contracts](../architecture.md#state-and-events).
- Core text transactions expose current text and finish as one history operation.
  Export ends the transaction before capturing its snapshot; live ink is excluded.
  Disposal releases callbacks and prevents late viewer publication.
