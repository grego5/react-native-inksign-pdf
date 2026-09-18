# PDFium package

This directory contains the pinned PDFium C API and mobile artifacts used by
the native compatibility-text implementation. All artifacts are sourced from
PDFium `chromium/8021`, commit
`784a524ddaa26d86c0f499625b97902095c26dfe`, version `154.0.8021.0`.

`manifest.json` is the source of truth for provenance, immutable release
checksums, architecture coverage, build arguments, and measured packaged sizes.
Android `libpdfium.a` archives were generated with the pinned
`bblanchon/pdfium-binaries` workflow at release commit
`9dd99a8991bed3a2f37658a31bcd5b403800fd03`, using static mode and the Android
NDK version recorded in the manifest. No PDFium binaries are checked in. The
static PDFium workflow publishes the generated libraries to the repository's
versioned GitHub Release; Gradle downloads and verifies that release asset
before CMake configures Android.

The iOS XCFramework is also release-hosted rather than checked in. A cloud
macOS workflow is provided at
`.github/workflows/build-static-pdfium-ios.yml`; it builds the three static
slices, assembles an XCFramework, and uploads it as a workflow artifact. The
workflow now also publishes the Android archives and iOS XCFramework as a
versioned GitHub Release with a `SHA256SUMS` file. The generated XCFramework
still requires macOS/Xcode integration and device/runtime validation before
being considered production-ready. The iOS PDFKit fallback remains required
until that validation is complete.

To run the build, push the repository to GitHub, open **Actions**, select
**Build static PDFium for iOS**, and choose **Run workflow**. No local Mac is
needed. The workflow uses the pinned `bblanchon/pdfium-binaries` release and
the `chromium/8021` upstream branch recorded above. The repository's Actions
settings must allow workflows to write releases. Once the release exists,
fresh npm installs on macOS fetch the static iOS XCFramework automatically;
Android Gradle builds fetch the static Android archives when they are not
present locally.

Only the public C headers are exposed to native implementation targets. Android
final-links the static PDFium archive into the module; the runtime renderer
remains Android `PdfRenderer`. iOS continues to render with PDFKit while its
PDFium path is experimental and unvalidated.
