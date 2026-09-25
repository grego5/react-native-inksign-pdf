# Android viewport and input

## Contract

- View/document state is UI-thread-owned. Viewport work requires a loaded page
  and usable layout; stale worker results cannot replace newer state.
- Geometry uses media-box-relative page units with a top-left origin. The shared
  transform drives tiles, ink, text, hit testing, and editor placement, while
  stored content remains in canonical units.
- `open()` and page switches fit and center the page unless options override it.
  Synchronous commands validate before returning; `getViewport()` throws when
  the document or layout is not ready.
- Page commands validate on the UI thread, then post the switch. A newer
  request silently supersedes an older one; `onPageChange` fires only after the
  target is installed, and post-return failures are logged natively.

## Text input

- `TextInteractionOverlay` owns hit testing, editing, dragging, keyboard
  avoidance, and one-shot placement. Text taps edit immediately; completed
  drags create at most one history mutation, while cancelled or unchanged
  interactions create none.
- New annotation direction comes from the explicit LTR/RTL choice or, in
  `auto`, the current IME subtype while the draft is empty. The first inserted
  text locks direction through keyboard changes and mixed scripts; erasing the
  full draft makes `auto` eligible to sample again. Missing subtype data keeps
  the current empty-editor direction, and IME reporting is best effort.
- Text-owned streams do not enter ink or navigation. Placement consumes one
  valid in-page tap after inverse-transforming it into page coordinates.
- An unselected text hit selects on long press and can drag during that hold.
  Once selected, movement past touch slop starts a drag immediately; a stationary
  tap edits it, and movement past slop on unselected text pans the viewport.
- The placement tap marks the bottom of the editor frame; horizontal anchoring
  remains left for LTR and right for RTL. Empty content width starts at one em.
  The measured editor frame is clamped to the page; near the top edge, this can
  move its bottom below the tap.
- Idle outlines, selected outlines, and text hit testing share the content
  bounds expanded by the editor's pixel padding at the current zoom. Saved
  annotation bounds keep native text-layout dimensions without that padding.
- Editor frames and active selection endpoints are reconciled through the
  shared page-to-view transform. Entering edit preserves the current zoom and
  pans the outer editor into the usable viewport; if it is too wide, focus stays
  around the active caret. Caret follow runs once after editor layout with the
  current page transform, keeping the caret and adjacent padded line within a
  24 dp margin where the page permits and using the keyboard-adjusted usable
  height. Viewport movement never changes the stored page anchor.
- After the placement tap ends, a drag that starts outside the editor pans the
  viewport while the editor remains active; the completed placement stream is
  required before a later drag can be routed this way.

## Ink and navigation input

- View mode owns page navigation; ordinary pan and pinch remain viewport input.
  RTL reverses page mapping. Reversal, context changes, mode changes,
  replacement, detachment, and disposal cancel pending navigation.
- Edit mode accepts one direct finger or stylus pointer. Unsupported tools,
  secondary contacts, and out-of-page points are rejected; samples use a frozen
  transform and pen configuration for the stroke.
