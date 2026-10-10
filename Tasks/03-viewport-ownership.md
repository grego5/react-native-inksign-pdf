# 03 - Own viewport and keyboard geometry

[Plan](../TASKS.md)

Status: Complete (static); runtime verification deferred
Complexity: High
Depends on: 02

## Objective and non-goals

Give viewport mutation, motion completion, and keyboard scroll space one owner.
Retain PDFKit and the established zoom/focus behavior; do not introduce a renderer
or change page geometry, text wrapping, or public options.

## Read before editing

- `ios/InkSignView+Viewport.swift`: `applyViewport`, `animateViewport`,
  `pageViewportScrollView`, `movePageViewport`, inset reconciliation, focus target,
  `ensureTextVisible`, double tap, placement viewport, current viewport snapshot.
- `ios/ViewportMotion.swift`: request replacement, display-link lifetime.
- `ios/InkSignView+Overlay.swift`: transform refresh and scale callbacks.
- `ios/InkSignView.swift`: scale observer, `scheduleZoomReport`, viewport fields.
- `ios/TextInteraction.swift`: keyboard observations, `followCaretIfNeeded`.
- `ios/TextCommands.swift`: `focusPreparedTextNow`.
- `.agents/skills/inksign-pdf-docs/references/swift-ios/viewport-input.md`.

## Preserved contract

Zoom and focus change together; focus settles once animation completes. Gesture,
mode, page, document, and overlay replacement cancel affected motion. Public
zoom events report settled scale/fit. Text placement applies its viewport only
after a valid tap; editing preserves captured text layout and canonical content.

## Implementation

1. Add `ios/ViewerViewportController.swift`, privately owned by the interaction
   coordinator. Move motion ownership, viewport request identity, keyboard inset
   state, and zoom-report sampling/deduplication there. Reuse `ViewportMotion`.
2. Centralize writes to PDFKit scale/destination, page scroll offset/zoom/insets,
   and programmatic viewport cancellation. Route initial presentation, pager
   configuration, field focus, session viewport, double tap, and placement through
   this boundary. Keep initial presentation immediate and interactive focus animated.
3. Confine discovery of PDFKit's active page scroll view to this component.
   Read actual geometry through the existing adapters. Preserve the outer pager.
   Do not add a second authoritative zoom/offset cache.
4. Move keyboard observation and occlusion conversion to the viewport owner.
   The text overlay reports editing begin/end and caret/outline rectangles.
   Preserve the current additive bottom-inset correction: live PDFKit geometry
   takes precedence; release only the keyboard adjustment still owned by us.
5. Process caret visibility with the current frame and safe visible rectangle.
   Framework geometry callbacks refresh dependent presentation; they must not
   recursively launch a competing focus animation. Preserve existing user-pan
   and typing-follow behavior.
6. Route animation success/failure and settled zoom events back through the
   coordinator. Validate captured page, geometry, request, and optional mode
   session at the owning boundary. Remove the migrated state from `InkSignView`
   and keyboard observers from the text overlay.

## Boundaries and completion

- UI mutation and display-link callbacks stay on the main thread. Teardown
  invalidates the link and settles its request; callbacks must allow reentry.
- Document layout orientation and committed geometry remain domain data. Only
  screen/page conversion and presentation geometry belong here.
- Done when all viewport writes use this owner and text input requests visibility
  without touching PDFKit scrolling. Leave no old mutation path as an alias.
- Static check: `git diff --check`; search all scale, destination, offset, and
  inset writes and trace their owner. Task 05 records platform verification.
- Proposed commit: `refactor(ios): centralize viewport and keyboard ownership`.

