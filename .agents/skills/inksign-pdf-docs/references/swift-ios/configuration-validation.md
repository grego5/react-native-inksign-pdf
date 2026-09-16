# iOS configuration and validation

## Configuration

The public props are defined in `src/PdfView.nitro.ts`.

- iOS applies `strokeColor` and `strokeMaxWidth` to the PencilKit pen. The
  default maximum width is 4 UIKit points.
- `strokeMinWidth` and `strokeSmoothing` are shared props but have no iOS
  effect; PencilKit owns pressure response, smoothing, caps, joins, and
  prediction.
- Pen changes are installed on the main thread. A change received during a
  stroke is queued until that transaction finishes.
- The native cache leaf is `inksignpdf`. An app may replace it with the single
  directory component in the
  `ReactNativeInkSignPdfCacheDirectoryName` Info.plist key.

## Validation boundary

The C++ and static source checks do not validate iOS rendering or runtime
behavior. macOS/Xcode is required for iOS XCTest, simulator, and device
validation. Runtime coverage should include document replacement and disposal,
rotated and non-zero-origin pages, viewport/mode transitions, PencilKit input,
page navigation, text editing, history, and export placement.

The lifecycle runner checks source-level ownership and lifecycle contracts, but
it cannot prove visual fidelity, gesture feel, animation timing, haptics, or
device performance. Report those as separate iOS runtime results.
