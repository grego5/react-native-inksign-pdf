# Third-party notices

## Google Ink

The vendored `third_party/google-ink` snapshot provides the upstream
`BrushTipExtruder` geometry closure. It owns the upstream mesh, outline,
constraint, and intersection algorithms behind `cpp/upstream/` for the staged
migration.

The snapshot is Copyright 2024 Google LLC and distributed under the Apache
License 2.0. Its exact revision, closure, and build-only portability patch are
documented in `third_party/google-ink/UPSTREAM.md`; the license text is in
`third_party/google-ink/LICENSE`.

The vendored Abseil dependency is Copyright Google LLC and distributed under
the Apache License 2.0. Its pinned revision and license are documented in
`third_party/abseil-cpp/UPSTREAM.md` and `third_party/abseil-cpp/LICENSE`.

## PDFium

The `third_party/pdfium` package contains PDFium `154.0.8021.0` from the
`chromium/8021` branch at commit
`784a524ddaa26d86c0f499625b97902095c26dfe`. The Android and iOS binaries are
distributed by the open-source `bblanchon/pdfium-binaries` project from the
same upstream revision. Artifact URLs, SHA-256 checksums, architecture slices,
and measured packaged sizes are recorded in `third_party/pdfium/manifest.json`.

The Android build uses static `libpdfium.a` archives generated from the pinned
`bblanchon/pdfium-binaries` workflow with `build_type=static`,
`pdf_is_complete_lib = true`, `use_custom_libcxx = false`, and Android NDK
`29.0.14206865`; their provenance, checksums, and sizes are in the manifest.
The large static Android and iOS binaries are published as checksummed GitHub
Release assets, which Gradle and the macOS npm postinstall fetcher consume.
No PDFium binaries are checked in; the iOS static release is explicitly marked
experimental/unvalidated until it is generated and runtime-tested.

PDFium is distributed under its BSD license. The package also includes the
licenses for its bundled third-party dependencies under
`third_party/pdfium/licenses/`.
