# Android viewport and input

## Ownership

- `SurfaceView` coordinates the active page and input routing.
- `InkDocumentController` owns the viewport, transform, tiles, and live
  drawing; `PageNavigationController` owns navigation and handoff.
- `TextInteractionOverlay` owns text hit testing, editing, dragging, keyboard
  interaction, and one-shot placement.
- View/document state is UI-thread-owned. Stale worker results are rejected or
  recycled.

## Viewport contract

- Viewport work requires a loaded page and usable layout. Canonical geometry is
  media-box-relative page units with a top-left origin; the shared transform is
  used for tiles, ink, text, hit testing, and editor placement.
- `open()` and page switches fit and center the page unless explicit viewport
  options are supplied. Focus and zoom are validated and clamped before state
  changes. Commands resolve when mapping and mode are ready, not when tiles
  finish.
- Text bounds, font sizes, and stored ink remain in canonical page units.
  Presentation padding, outlines, selection, and editor backgrounds are not
  stored or exported.
- `getViewport()` captures UI-thread state and rejects stale deferred results.

Text editing uses the shared viewport for placement and keyboard avoidance. A
text tap edits immediately; a completed drag creates at most one history
mutation, and cancelled/unchanged interactions create none.

## Page navigation

- View mode owns boundary navigation; ordinary pan, pinch, vertical, inward,
  and ambiguous streams remain viewport input. RTL reverses page mapping.
- Navigation captures the current page/viewport context and requires a matching
  ready preview. Reversal, context changes, mode changes, replacement,
  detachment, or disposal cancel the switch.
- A successful switch installs one fit-centered target mapping. Stale preview
  or tile callbacks cannot mutate presentation, and `onPageChange` fires only
  after the target mapping is installed.

## Input routing

- Edit mode accepts one direct finger or stylus pointer. Unsupported tools,
  secondary contacts, and out-of-page points are rejected. Samples are sent to
  native stroke modeling in order with transform and pen configuration frozen
  for the stroke.
- Text-owned streams do not enter ink or navigation. Outside-editor movement
  can transfer once to viewport pan; focus loss settles the editor or cancels
  pending placement.
- `insertAnnotationOn` arms one valid in-page tap. The tap is inverse-transformed
  once into page coordinates, consumes its stream, disables placement, and
  creates one draft. Out-of-page downs leave placement armed.
