# iOS configuration and validation boundary

- Public props are defined in
  [`src/InkSignView.nitro.ts`](../../../../src/InkSignView.nitro.ts).
- Nitro configuration setters capture incoming values and apply UIKit-backed
  changes on the main thread. Pen changes wait for an active drawing transaction
  to finish.
- iOS maps supported stroke settings to PencilKit. PencilKit owns pressure,
  smoothing, caps, joins, and prediction.
- The module owns temporary artifacts; the host app can configure their cache
  directory.

- Run XCTest and simulator validation on macOS with Xcode.
- Review visual fidelity, gesture feel, haptics, and device performance on
  representative devices where relevant.

- See [development.md](../development.md) for validation entry points and scope.
