# History and callbacks

- Each page owns one ordered `InkSignPdfPageContentHistory` for committed
  PencilKit drawing and text annotations. Its immutable content snapshots use
  canonical media-box-relative text position/font size and explicit newlines;
  text bounds are intrinsic to the supplied font size and are clipped using
  the page-size rule shared with Android. UIKit editor and selection state is
  not stored in page content.
- Completed iOS ink remains one page-local committed `PKDrawing` mapped to
  canonical page coordinates. Android uses immutable page-space contour
  collections; these are separate platform representations, not two iOS
  backends.
- An active PencilKit interaction owns its live drawing. After
  `canvasViewDidEndUsingTool`, the interaction remains in an ended-but-updating
  state until PencilKit's final `canvasViewDrawingDidChange` delivery; that
  interaction appends exactly one native history action. Programmatic snapshot
  installation never creates a transaction or history action.
- Live PencilKit content is disposable until the coordinator commits the
  transaction; it never becomes history directly.
- Undo/redo/clear cancel active or ended-but-updating ink and settle the
  transient text interaction before restoring whole page-content snapshots.
  Text mutations cancel competing live ink before changing the shared history,
  so the two content types cannot commit against different baselines. Export
  does not settle or cancel input; it reads a copied committed snapshot.
- Text creation, edit, move, font-size change, and removal are discrete
  page-content actions. An edit or drag session is represented by one action;
  the interaction owner supplies the coalesced before/after snapshots.
- Clearing the page is one undoable clear action containing the prior committed
  drawing and text annotations.
- `onStateChange` reports only changed `canUndo`, `canRedo`, and `isDirty`
  values for the active page, with `isDirty` aggregated across all pages,
  except for forced reset/load notifications. Text-only page content makes
  the document dirty and participates in the active page's undo/redo state.
- Switching pages installs only the target page's committed drawing and text
  content and never
  moves history actions between page entries. Delayed PencilKit callbacks are
  rejected or restored against the active page after a switch.
- Release callbacks during disposal; no callback may run after the view drops.
