# Android example app

This is a normal React Native New Architecture consumer app for validating the
Nitro view on Android. It consumes the package from the repository root, so
the package Android library and its instrumentation tests are included through
React Native autolinking.

The app screen uses the system document picker to select a PDF, asks the picker
for a caller-owned local copy, reports the zero-based active page, switches
between view and edit mode, and exposes previous/next navigation plus native
undo/redo/clear, text-annotation, and all-page export controls. Placement labels
and text-command enablement are derived from the native `onStateChange.mode`
snapshot. Platform prediction is always enabled for eligible native input;
prediction is preview-only and never enters the exported PDF. Undo/redo/clear
are page-local; the export/dirty state covers the whole document.
Exported PDFs are written as temporary native cache artifacts. The example
copies each signed result to a user-selected durable destination before opening
it in the system document viewer. The selected source copy remains caller-owned
and must stay readable until the mounted view's last export; the example retires
each exact picker-created copy after replacement, a failed open, or unmount.
Native cleanup never targets these source copies.

## Prerequisites

- JDK 17 or newer
- Android SDK 36 with extension 18 and the configured build tools

From the repository root, install and build the local package first, then
install the consumer app:

```powershell
npm install
npm run build
cd example
npm install
```

The focused Kotlin test module remains available under `:viewport-tests` and
does not require the React Native app at runtime.

## Checks

Run the focused Kotlin tests:

```powershell
.\gradlew.bat :viewport-tests:testDebugUnitTest --tests com.margelo.nitro.inksignpdf.PageViewportTest --no-daemon --console=plain
```

Build and install the normal React Native app:

```powershell
cd example\android
.\gradlew.bat :app:installDebug --no-daemon --console=plain
```

Start Metro in another terminal:

```powershell
cd example
npm start
```

Or build, install, and start Metro through React Native:

```powershell
npm run android
```

For a manual smoke test, install the app, tap **Choose PDF**, and select a
multi-page local PDF with different page sizes. The picker-created local copy
is opened directly. Tap **Place text**, tap the page once, and verify the label
returns to **Place text** while the native editor focuses. Enter Latin and RTL
text, including multiline and wide text near both page edges; dismiss it, tap
the committed text to edit it, and long-press/drag it. A completed unchanged
long press should retain selection so **Text +**, **Text −**, and **Remove
text** remain available. Verify outside taps settle while outside drags pan
without dismissing the editor, and check the padded outline, caret/keyboard
avoidance, wrapping, zoom, page changes, and page-local mixed undo/redo state.
Commands without a selection show the native error through the example alert
path. Swipe between pages as well as using **Previous**/**Next** and verify the
page label and boundary button states stay synchronized. **Export** opens a
Save As flow so the all-page signed result is copied out before it is opened.
Capture a Perfetto trace to inspect the committed and predicted input markers;
prediction has no runtime toggle.
