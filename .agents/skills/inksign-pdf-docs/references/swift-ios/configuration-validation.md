# iOS configuration and validation

The public props are defined in
[`src/InkSignView.nitro.ts`](../../../../src/InkSignView.nitro.ts). iOS maps the
supported stroke settings to PencilKit; PencilKit owns pressure response,
smoothing, caps, joins, and prediction. Native artifact storage belongs to the
module and may be configured by the host app.

iOS runtime validation requires macOS and Xcode. XCTest and simulator runs check
native behavior and integration; they do not establish visual fidelity, gesture
feel, haptics, or device performance. Those require separate visual and
physical-device review where relevant.

Use the iOS simulator and device validation entry points described in
[development.md](../development.md). Keep the selected validation scope narrow
for local changes and expand it when the native dependency or platform boundary
changes.
