# History and callbacks

- Each page owns an ordered history of committed `PKDrawing` content and text
  annotations in canonical page coordinates.
- `hasInk()` reads whether the active page's committed drawing has strokes;
  page navigation, undo, redo, and clear are reflected directly by history.
- `clearInk()` cancels live ink and records an empty drawing as one undoable
  change, preserving text and source PDF content. Empty ink is a no-op.
- Live strokes, predictions, the text editor, and selection stay outside history.
- A PencilKit stroke commits once per drawing transaction. Installing a drawing
  programmatically does not create history.
- Text creation, editing, movement, resizing, removal, and clear are discrete
  undoable actions.
- Undo, redo, and clear settle transient input before restoring a page snapshot.
- `onStateChange` reports undo/redo availability for the active page; dirty state
  is aggregated across the document.
- Page changes install that page's committed content. Delayed ink callbacks
  cannot commit to a different page.
- Export reads committed snapshots without changing live input. Disposal releases
  callbacks and prevents later results from reaching the view.
