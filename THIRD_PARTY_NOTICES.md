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

The `core/third_party/pdfium` package contains PDFium `158.0.8125.0` from
`chromium/8125` at commit `43d55e429cf72c21e9a1e60475b50feefa16fda9`.
Android links static archives built with NDK `27.1.12297006` and pinned
`bblanchon/pdfium-binaries` tooling. Release provenance, archive sizes, and
SHA-256 checksums are recorded in `core/third_party/pdfium/manifest.json`.
Gradle downloads and verifies the Android assets. The iOS pod downloads the
checksummed Apple static XCFramework and links its target slice. Binaries are
not committed; both distributions carry the bundled dependency licenses.

PDFium is distributed under its BSD license. The package also includes the
licenses for its bundled third-party dependencies under
`core/third_party/pdfium/licenses/`.
