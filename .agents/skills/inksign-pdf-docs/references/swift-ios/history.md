# History and callbacks

- Each page owns one ordered history of committed `PKDrawing` content and text
  annotations. Content is stored in canonical page coordinates; the temporary
  text editor and selection state are not part of history.
- A PencilKit stroke is committed once, after the final drawing-change callback
  for its tool transaction. Live drawing is disposable until then, and
  programmatic drawing installation does not create history.
- Text creation, editing, movement, resizing, removal, and clear are discrete
  undoable page-content actions. Undo, redo, and clear first cancel or settle
  transient input so every action restores a complete page snapshot.
- `onStateChange` reports `canUndo` and `canRedo` for the active page;
  `isDirty` is aggregated across the document. Text-only changes participate
  in the same history.
- Page changes install only the target page's committed content. Delayed
  PencilKit callbacks cannot commit against another page.
- Export reads copied committed snapshots; it does not commit or cancel live
  input. Disposal releases callbacks and prevents later results from reaching
  the view.
