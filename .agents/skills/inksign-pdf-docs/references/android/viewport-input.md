# Android viewport and input

## Ownership

- SurfaceView coordinates the active page, input routing, and page identity.
- InkDocumentController owns the active-page viewport, transform, tile
  planning, and live drawing.
- PageNavigationController owns boundary navigation, previews, and page
  handoff.
- TextInteractionOverlay owns text hit testing, editing, dragging, keyboard
  interaction, and one-shot placement. Empty overlay space passes through to
  the surface.
- View and document state are UI-thread-owned. Worker results are accepted only
  for the current document/page/request identity; stale bitmaps are rejected
  or recycled.

## Viewport contract

- Viewport work requires a loaded page and usable layout. Canonical geometry is
  PDF media-box-relative page units with a top-left origin; the shared
  page-to-view transform is used for tiles, ink, text, hit testing, and editor
  placement.
- open() and successful page switches fit and center the page. Omitted viewport
  options preserve focus and zoom; an empty object fits the page; a focus pair
  targets that page point; and zoom alone preserves focus. Coordinates must be
  paired. Non-finite or non-positive values, unloaded documents, and unusable
  layouts are rejected before state changes. Focus is clamped to the page and
  zoom to 0.1...16.
- Explicit viewport targets animate for 160 ms and are cancelled by touch,
  replacement, detachment, or disposal. A resolved command means mapping and
  interaction mode are ready, not that asynchronous tiles have finished.
  During motion, the current tile set remains visible until the next
  quantized set is ready; prefetched tiles are never a fallback.
- Text bounds, font sizes, and stored ink remain in canonical page units.
  Text uses explicit lines and intrinsic longest-line sizing. Text-field hints
  are only initial direction hints for an empty editor; strong content
  direction wins. Presentation padding, outlines, selection state, and editor
  backgrounds do not enter history, previews, or export.
- A committed-text tap edits immediately. A long press owns a native-haptic
  drag; release commits at most one replacement when the position changed.
  Unchanged holds and cancelled drags create no history entry. Hit testing uses
  a 40 dp minimum target unioned with the visible outline, with overlap order
  following reverse paint order.
- Entering text editing raises zoom to the configured double-tap target only
  when needed and focuses the editor/caret through the shared viewport. IME
  avoidance and later typing or selection changes apply the minimum
  shared-transform movement needed to keep the caret visible; the overlay is
  never translated independently. Removing the IME inset preserves focus.
- getViewport captures the UI-thread viewport and rejects deferred results whose
  document generation is stale.

## Page navigation

- View mode owns page navigation. A boundary horizontal drag may transfer after
  the 8 dp dead zone; direction is horizontal-dominant, pull is capped at
  40 dp, and settlement arms at 30% of the captured visible width. RTL
  reverses the page mapping. Vertical, inward, tap/double-tap, pinch, and
  away-from-boundary streams remain viewport input.
- Navigation captures the down-time page/viewport context and requires a
  matching ready preview before arming. Reversal, context changes, mode
  changes, replacement, detachment, or disposal cancel the switch. Settlement
  installs one fit-centered target mapping; cancelled switches leave the
  current page and viewport unchanged.
- Preview and tile identities are independent. Stale callbacks cannot mutate
  presentation or install a page. onPageChange fires only after the target
  mapping is installed.

## Input routing

- Edit mode accepts one direct finger or stylus pointer. Secondary contacts,
  unsupported tools, and out-of-page points are rejected. Historical and
  current samples are forwarded in order as one native batch of at most 256
  samples, with the page transform and nib configuration frozen at stroke
  start.
- Text-owned streams do not enter ink or navigation. Movement before a
  long-press drag crosses touch slop only once to the viewport; an active hold
  keeps ownership. Outside-editor taps settle and clear the editor, while an
  outside stream that crosses slop transfers once to viewport pan and retains
  keyboard/caret selection. Window-focus loss settles the editor or cancels
  pending placement.
- insertAnnotationOn arms exactly one valid in-page tap without creating
  content or opening the keyboard. The tap is inverse-transformed once into
  page coordinates, consumes its stream, disables placement, and creates one
  draft. The smallest containing PDF field supplies the canonical top-left
  origin; source order breaks equal-area ties. A free tap centers the initial
  editor bounds and clamps them to the page. Out-of-page downs leave placement
  armed.
