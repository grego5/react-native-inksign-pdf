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
- Text-owned streams do not enter ink or navigation. Placement consumes one
  valid in-page tap after inverse-transforming it into page coordinates.

## Ink and navigation input

- View mode owns page navigation; ordinary pan and pinch remain viewport input.
  RTL reverses page mapping. Reversal, context changes, mode changes,
  replacement, detachment, and disposal cancel pending navigation.
- Edit mode accepts one direct finger or stylus pointer. Unsupported tools,
  secondary contacts, and out-of-page points are rejected; samples use a frozen
  transform and pen configuration for the stroke.
