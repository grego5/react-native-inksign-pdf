# 01 — Pin and package PDFium for Android and iOS

[Back to plan index](../TASKS.md)

Status: Planned

## Objective

Establish one reproducible, pinned PDFium distribution that exposes the public
C API to the repository's Android and iOS native targets, with documented
revision, provenance, license, architectures, and binary-size impact.

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

- The repository has no PDFium dependency.
- Android builds one `ReactNativeInkSignPdf` shared library for configured React
  Native ABIs. iOS source is packaged through CocoaPods.
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
3. Integrate headers and native libraries into Android CMake/Gradle and iOS
   CocoaPods packaging. Limit Android to configured ABIs and include device plus
   simulator slices required by the iOS development setup.
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

- Build the Android debug APK and PDFium native smoke target.
- Build the pod or iOS test host when macOS/Xcode is available.
- Verify artifact checksums and required architecture slices.
- Run `git diff --check -- ':!nitrogen/generated/**'`.
- If iOS infrastructure is unavailable, report the exact unvalidated slices and command.

## Completion criteria

- One pinned revision supplies both platforms.
- Required public C APIs link successfully.
- Provenance, license, checksums, architectures, and size deltas are recorded.
- No runtime PDF behavior changes.

## Proposed commit title

`build(native): package pinned pdfium`
