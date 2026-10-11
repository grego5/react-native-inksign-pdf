# Android native artifacts

- PDFium source, ABI archives, and checksums are pinned in
  `core/third_party/pdfium/manifest.json`. Gradle verifies the release assets and
  each extracted library, caching them under `android/build/pdfium`. A changed
  pin invalidates archives whose size or hash differs. Public headers and
  licenses are vendored alongside the manifest.
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
