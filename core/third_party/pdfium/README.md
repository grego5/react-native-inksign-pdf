# PDFium package

This directory contains the public PDFium headers, licenses, and provenance
metadata used by the native rendering and page-assembly adapters. The source is
pinned to PDFium `157.0.8086.0` on `chromium/8086`; see `manifest.json` for the
exact revision and build provenance.

The native binaries are not committed to Git. Their archive sizes and SHA-256
checksums are pinned in `manifest.json`. Gradle fetches the
`pdfium-157.0.8086.0-static` GitHub Release into the ignored
`android/build/pdfium` directory and verifies its artifacts.

Android uses static `libpdfium.a` archives that are final-linked into the native
module. No separate `libpdfium.so` is packaged.

The Android and Apple build workflows use pinned upstream source and
`bblanchon/pdfium-binaries` tooling. `publish-pdfium.yml` publishes their outputs
independently, with separate platform checksum lists.
