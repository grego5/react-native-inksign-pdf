# History and callbacks

- Each page owns an ordered history of committed `PKDrawing` content and text
  annotations in canonical page coordinates.
- Page `getState()` reads committed drawing/text, dirty state, and history
  availability. See [state contracts](../architecture.md#state-inspection-and-events).
- `clearInk()` cancels live ink and records an empty drawing as one undoable
  change, preserving text and source PDF content. Empty ink is a no-op.
- Live strokes, predictions, the text editor, and selection stay outside history.
- A PencilKit stroke commits once per drawing transaction. Installing a drawing
  programmatically does not create history.
- Text creation, editing, movement, resizing, removal, and clear are discrete
  undoable actions.
- Undo, redo, and clear settle transient input before restoring a page snapshot.
- State/page callbacks publish on the main thread and deduplicate their payloads.
  Payload fields and dirty-state rules follow the shared
  [state contracts](../architecture.md#state-inspection-and-events).
- Page changes install that page's committed content. Delayed ink callbacks
  cannot commit to a different page.
- Export reads committed snapshots without changing live input. Disposal releases
  callbacks and prevents later results from reaching the view.
