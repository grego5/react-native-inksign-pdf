# iOS viewport and input

## Viewport and modes

- `ViewerViewportController` owns scale, focus, zooming-page scroll offset, motion,
  and keyboard insets; the outer pager retains its offset.
- `session.setViewport()` preserves when omitted; `{}` fits. Absolute zoom and
  paired x/y set focus. Text placement applies viewport options after a valid tap.
  `doubleTap.zoom` is independent of placement zoom.
- `ViewportMotion` applies zoom/focus together. Field focus waits for pending page
  presentation before navigating/animating; core publication remains independent.
  Focus resolves after motion; user pan/pinch, overlay reset, or mode/page/document
  replacement cancels it.
- Caret following preserves zoom. Keyboard avoidance owns an additive bottom
  inset, reconciled after zoom and removed when editing ends.
- Display precision uses the viewport's trait display scale. Scene deactivation
  cancels live ink only when the notification matches the viewer's current window
  scene; document-owned selection survives ordinary scene inactivity.
- `onZoomChange` waits for stable scale/fit and finished PDFView gestures; emit
  only with ready presentation. Shared [events](../architecture.md#state-and-events).
- `ViewerInteractionCoordinator` derives exclusive input policy from picker,
  text activity, base view/ink mode, and presentation readiness. PDFKit/PencilKit
  reconcile this policy on overlay attachment/layout.
- `PageGeometry` maps visible-box canonical content to PDFKit CropBox presentation.
  Public focus/bounds use displayed top-left points. Shared
  [geometry](../architecture.md#geometry-and-text-targets) and
  [mode/picker lifetime](../architecture.md#commands-and-lifetime).

## Text and ink

- Manual placement follows the shared [text layout contract](../architecture.md#layout-and-editing).
  TextKit measures within core flow capacity; editor frames do not redefine it.
- Snapping uses cached labels: above-rule tolerance is max(screen tolerance,
  label line-height), with editor line-height for unlabeled rules. Below-rule
  tolerance is screen-based. PDFium supplies solid/dotted rule candidates,
  including table-border candidates.
- TextKit owns live wrapping/caret/selection. Measure at final wrapping width,
  include the trailing empty line, and enforce the renderer's line-height minimum.
  Apply bounds before caret following; remeasure before commit.
- The core owns effective text; the overlay owns editor state. Mode transitions
  end the transaction or cancel untapped placement. Shared
  [bounds/line admission](../architecture.md#layout-and-editing) applies.
- Native text options require line counts representable as nonnegative integers.
  Programmatic value/options writes prepare fonts and layout before ending the
  active edit; rejected writes preserve the draft and history.
- Editor/rendering/hit-testing/dragging map captured layout → canonical → display.
  Moves update target placement; named source association remains stable.
- Module-text touch admission gives overlay tap/long-press/drag priority over
  PDFKit selection. Ink touches pass through the text overlay to PencilKit;
  the canvas yields outside ink mode.
- Explicit direction wins; `auto` follows app layout; omission uses
  `textDirection` or app layout when unset/auto. Placement captures direction
  when armed. Prop changes reflow the active editor inside unchanged fixed bounds
  and reconcile caret visibility; commit saves resolved direction.
- View-free core resolution (`resolveInputUnderline`, programmatic text) reads
  `RCTI18nUtil.isRTL` per call, as Android reads `I18nUtil`; UIKit's bundle
  localization direction stays LTR in apps without RTL localizations.

## Prepared page text

- Import-time PDFium analysis retains canonical glyph bounds, UTF-16 ranges,
  complete labels, and rule endpoints. Display projections/directional pairs
  serve field resolution and manual snapping. Finalize formatting before measuring
  visible bounds.
- Shared [lookup/value/focus](../architecture.md#geometry-and-text-targets);
  [cache lifetime](view-lifecycle.md#ownership).

## Navigation and picking

- Page selection preserves pending presentation until a replacement passes readiness
  checks. Selecting the active page leaves its presentation intact.
- `pagerDirection` sets PDFView semantic direction independently of text;
  auto follows system layout. PDFKit owns physical swipes.
- UIKit distinguishes picker taps from pan/pinch; text/ink input is inactive.
  Picker cancellation/restoration follows the shared command contract.
