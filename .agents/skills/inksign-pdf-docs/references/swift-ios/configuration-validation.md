# iOS configuration and validation

## Configuration

The public props are defined in `src/InkSignView.nitro.ts`.

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

The manually triggered `Build iOS ad hoc IPA` workflow uses the `example`
Expo consumer to archive and sign an installable iOS app.
It requires `IOS_DISTRIBUTION_P12_B64`, `IOS_DISTRIBUTION_P12_PASSWORD`, and
`IOS_AD_HOC_PROFILE_B64` repository secrets. The profile must authorize the
consumer bundle identifier and its registered test devices.

The manually triggered `Compile iOS native module` GitHub Actions workflow
builds the pod target on a macOS runner using the `example` Expo consumer.
It installs this checkout as a packed local dependency, generates an iOS
project, installs pods, and compiles `ReactNativeInkSignPdf` for the simulator
without signing or making an EAS build. Its Xcode log is uploaded as an
artifact. This checks native compilation only; it does not run XCTest or
validate runtime behavior.
