# Android native artifacts

- Android builds use the pinned release record in
  `android/ink-engine-release.json`. Gradle downloads and verifies the
  InkEngine archive during the native build, then caches ABI libraries under
  `android/build`.
- The npm package does not include InkEngine static libraries or Google
  Ink/Abseil sources. A verified cache can be reused offline; a missing or
  invalid cache requires access to the pinned GitHub Release.
- Repository developers can compile checked-out sources with
  `-PReactNativeInkSignPdf_useSourceInkEngine=true`. Consumer builds use the
  pinned release by default.
