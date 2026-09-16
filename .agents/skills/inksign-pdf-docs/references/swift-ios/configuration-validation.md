# Configuration and validation

## Configuration

- Public props: color, minimum/maximum width, smoothing, and the shared
  velocity-sensitive configuration. The public source of truth is
  `src/PdfView.nitro.ts`.
- The moving rounded head is intrinsic to the first modeled tip and its
  startup prefix; platform configuration does not expose an independent
  start-cap size or toggle.
- Android defaults are 2.0–4.0 logical display units with 0.4 Google Ink
  smoothing.
- On iOS, color is applied to the PencilKit pen and `strokeMaxWidth` is the
  nominal pen width in UIKit points. It is converted to page units using the
  validated page-to-overlay scale captured immediately before a stroke.
- `strokeMinWidth` and `strokeSmoothing` remain accepted shared props but have
  no iOS effect because PencilKit owns pressure response and smoothing.
- Apply iOS tool changes between strokes; queue a new configuration while a
  stroke is active.
- Native defaults include one-page media-box editing, direct finger/Pencil
  input, one active drawing transaction, and platform-owned prediction.
- The native cache leaf defaults to `inksignpdf`. An application may set the
  validated single-component `ReactNativeInkSignPdfCacheDirectoryName` Info.plist
  key before startup. Native creates and scavenges that root once per process;
  it exposes no cache-directory or cleanup API.

## Validation boundary

- Fast checks: C++ release tests and TypeScript/generated integration.
- iOS device validation requires macOS/Xcode and should cover:
  - rotations 0/90/180/270 and negative media-box origins;
  - overlay bounds and detach/reattach ordering;
  - pan, pinch, deceleration, and edit-mode gesture isolation;
  - LTR/RTL neighboring-preview identity and committed target identity;
  - portrait and rotated/non-zero-origin media boxes with committed ink in
    page-turn preview pixel fixtures;
  - finger/Pencil coalesced input and prediction;
  - reload, history, export placement, recycling, and 60/120 Hz profiling.
- Do not claim iOS device completeness from standalone C++ tests.
- The repository lifecycle runner checks source immutability, cache artifact
  classification, output ownership, and presence of the pod XCTest contract
  statically. The `LifecycleTests` pod test spec exercises the production open
  readiness policy and verifies that a retained programmatic page-switch
  completion does not retain its view. It also exercises page-turn gesture
  state, non-retaining settlement ownership, stable-callback preservation,
  pending page-switch handoff, delayed-overlay readiness,
  delayed-callback cancellation,
  replacement, and disposal paths. XCTest injects deterministic preview-worker
  and animation-driver dependencies and advances explicit frames. Running those tests and device runtime
  acceptance still requires macOS/Xcode and remains a separate validation
  result; static source-contract checks do not validate visual preview
  appearance,
  resistance feel, animation timing, or haptic delivery.
