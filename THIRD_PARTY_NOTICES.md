# Third-party notices

## Google Ink

The vendored `core/third_party/google-ink` snapshot provides the upstream
`BrushTipExtruder` geometry closure. It owns the upstream mesh, outline,
constraint, and intersection algorithms behind `core/ink-engine/upstream/` for the
staged
migration.

The snapshot is Copyright 2024 Google LLC and distributed under the Apache
License 2.0. Its exact revision, closure, and build-only portability patch are
documented in `core/third_party/google-ink/UPSTREAM.md`; the license text is in
`core/third_party/google-ink/LICENSE`.

The vendored Abseil dependency is Copyright Google LLC and distributed under
the Apache License 2.0. Its pinned revision and license are documented in
`core/third_party/abseil-cpp/UPSTREAM.md` and `core/third_party/abseil-cpp/LICENSE`.

Normal Android package builds do not ship these Google Ink or Abseil source
trees. Gradle downloads the pinned `ink-engine-1.0.0-android-static.zip`
release and verifies it before linking the ABI-specific static archives. The
release contains the corresponding Google Ink and Abseil license files; the
release pin and checksums are maintained in `android/ink-engine-release.json`.

## PDFium

The `core/third_party/pdfium` package contains PDFium `154.0.8021.0` from the
`chromium/8021` branch at commit
`784a524ddaa26d86c0f499625b97902095c26dfe`. This repository builds the
static Android archives and iOS XCFramework from that source revision using
the pinned `bblanchon/pdfium-binaries` workflow and patches. The published
release URLs, SHA-256 checksums, architecture slices, and measured sizes are
recorded in `core/third_party/pdfium/manifest.json`.

The Android archives and iOS XCFramework are generated from the pinned
`bblanchon/pdfium-binaries` workflow with `build_type=static`. Android uses
NDK `27.1.12297006`. The workflow publishes static Android and iOS binaries
as checksummed GitHub Release assets for Gradle and the macOS npm postinstall
fetcher after both platforms finish successfully.
No PDFium binaries are checked in. Archive structure and symbols are validated
in CI; Android device acceptance and iOS runtime integration remain separate
validation steps, and iOS is explicitly experimental until runtime-tested.

PDFium is distributed under its BSD license. The package also includes the
licenses for its bundled third-party dependencies under
`core/third_party/pdfium/licenses/`.
