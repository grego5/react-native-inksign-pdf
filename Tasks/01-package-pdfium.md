# 01 — Pin and package PDFium for Android and iOS

[Back to plan index](../TASKS.md)

Status: Complete for Android; iOS experimental/WIP

## Objective

Establish one reproducible, pinned PDFium distribution that exposes the public
C API to the repository's Android and iOS native targets, with documented
revision, provenance, license, architectures, and binary-size impact. Android
is validated as a static final-link dependency; iOS remains explicitly
experimental until macOS/Xcode validation is available.

## Non-goals

- Do not implement text extraction or change runtime rendering.
- Do not replace either platform's base PDF renderer.
- Do not expose PDFium through the Nitro or JavaScript API.

## Read before editing

- `android/CMakeLists.txt` and `android/build.gradle`: native target and ABI ownership.
- `react-native-inksign-pdf.podspec`: iOS source, framework, and test packaging.
- `CMakeLists.txt`: existing shared C++ dependency conventions.
- `package.json`: published-file allowlist and package scripts.
- `.agents/skills/inksign-pdf-docs/references/development.md`: validation workflow.

## Current behavior and invariants

- PDFium is pinned and packaged under `third_party/pdfium`.
- Android builds one `ReactNativeInkSignPdf` shared library for configured React
  Native ABIs and final-links the static Android PDFium archive for each ABI.
  iOS source is packaged through CocoaPods with the release-hosted static
  XCFramework; iOS runtime integration remains experimental and unvalidated.
- Existing third-party source and notices must remain reproducible; generated
  Nitrogen files are never edited manually.

## Implementation steps

1. Evaluate available PDFium source/prebuilt distributions against four hard
   requirements: identical PDFium revision on both platforms, arm64 Android and
   iOS support, public `fpdfview.h`/`fpdf_text.h`/`fpdf_edit.h` APIs, and a
   reproducible non-commercial build or artifact source. Record rejected
   candidates and the reason briefly in a version manifest.
2. Pin the selected PDFium commit and artifact checksum. Do not track an
   unversioned `latest` binary or depend on separate unrelated Android/iOS wrappers.
3. Integrate headers and static Android archives into CMake/Gradle and the
   release-hosted static iOS XCFramework into CocoaPods. Limit Android to
   configured ABIs and document the unvalidated iOS runtime.
4. Add the PDFium BSD license and third-party notice to the package.
5. Add one native smoke target per platform that initializes PDFium, destroys
   its library context, and links the required text APIs.
6. Record incremental packaged binary size for Android release ABIs and the iOS
   framework; report it without inventing a size gate.

## Ownership and API rules

- PDFium initialization is process-wide native state; a later task provides its
  synchronized owner. The smoke test does not establish an app-facing singleton.
- Keep PDFium symbols and headers private to native implementation targets.
- Do not commit credentials, machine-local paths, or downloaded build caches.

## Tests and validation

- Build the Android debug APK and run the final-module PDFium instrumentation
  smoke test on a connected device.
- Build the pod or iOS test host when macOS/Xcode is available.
- Verify static archive magic/type, required symbols, architecture members,
  package contents, checksums, and required headers.
- Run `git diff --check -- ':!nitrogen/generated/**'`.
- If iOS infrastructure is unavailable, report the exact unvalidated slices and command.

## Completion criteria

- One pinned revision supplies both platforms' headers and provenance.
- Android's required public C APIs link successfully into the final module and
  initialize/destroy successfully on a connected device.
- iOS packaging is present but remains marked experimental and unvalidated.
- Provenance, license, checksums, architectures, and size deltas are recorded.
- No runtime PDF behavior changes.

## Delivered

- Pinned PDFium `154.0.8021.0` and the exact upstream commit in
  `third_party/pdfium/manifest.json`.
- Configured release-hosted Android `arm64-v8a` and `x86_64` static
  `libpdfium.a` archives; Android has no separately packaged `libpdfium.so`.
- Final-linked the Android smoke code into `ReactNativeInkSignPdf` and added a
  connected instrumentation test that executes PDFium initialization and
  destruction.
- Removed the checked-in iOS dynamic framework slices; the GitHub macOS
  workflow builds and publishes the static device and universal simulator
  XCFramework without requiring a local Mac. The PDFKit fallback remains in
  place until the static artifact is integrated and runtime-validated.
- Added private public-C headers, CocoaPods/CMake/Gradle integration, licenses,
  provenance, checksums, static-archive/symbol/architecture/package checks,
  measured size impact, and release-asset download support for large binaries.

## Proposed commit title

`build(native): make android pdfium static`
