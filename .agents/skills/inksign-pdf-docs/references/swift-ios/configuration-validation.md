# iOS configuration and validation boundary

The public props are defined in
[`src/InkSignView.nitro.ts`](../../../../src/InkSignView.nitro.ts). iOS maps the
supported stroke settings to PencilKit; PencilKit owns pressure response,
smoothing, caps, joins, and prediction. Native artifact storage belongs to the
module and may be configured by the host app.

iOS runtime validation uses macOS and Xcode. XCTest and simulator runs cover
native behavior and integration. Visual fidelity, gesture feel, haptics, and
device performance are assessed through visual review and representative device
checks where relevant.

See [development.md](../development.md) for validation entry points and scope.
