# iOS configuration and validation boundary

- Public props are defined in
  [`src/InkSignView.nitro.ts`](../../../../../src/InkSignView.nitro.ts).
- Nitro configuration setters capture incoming values and apply UIKit-backed
  changes on the main thread. Pen changes wait for an active drawing transaction
  to finish.
- iOS maps supported stroke settings to PencilKit. PencilKit owns pressure,
  smoothing, caps, joins, and prediction.
- `strokeMaxWidth` is PencilKit's nominal width in screen points (default 4).
  `strokeMinWidth` and `strokeSmoothing` apply only to Android.
- Tool width divides configured width by canvas-to-window scale and canvas zoom.
  It refreshes before drawing and stays fixed during the stroke; committed ink
  scales with the viewport.
- Working artifacts belong to the core; successful exports belong to the caller.
  See [export](export.md).

- Run XCTest and simulator validation on macOS with Xcode.
- Review visual fidelity, gesture feel, haptics, and device performance on
  representative devices where relevant.

- See [development.md](../development.md) for validation entry points and scope.
