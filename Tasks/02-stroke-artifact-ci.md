# Build and publish verified Android artifacts

Back to [TASKS.md](../TASKS.md).

Status: Complete

## Objective

Add GitHub Actions coverage that builds, validates, and publishes the bundled
ink-engine archives from a full repository checkout.

## Non-goals

- Do not change the existing PDFium workflow or PDFium source distribution.
- Do not make CI-generated binaries the only way to run native tests.
- Do not publish unverified or ABI-ambiguous archives.
- Do not publish tracing-enabled or debug-instrumented archives as the normal
  npm artifacts.

## Read before editing

- `.github/workflows/build-and-publish-pdfium.yml`: workflow conventions,
  pinned Android NDK, artifact staging, checksum validation, and release upload.
- `android/build.gradle`: supported PDFium ABIs and NDK compatibility check.
- `Tasks/01-bundled-stroke-archive.md`: archive contents and metadata contract.
- `tools/test-native.ps1`: supported native build/test runner behavior.
- `tools/verify-pdfium.ps1`: archive validation style to mirror where useful.

## Current behavior and invariants

- The repository pins Android NDK `27.1.12297006` for PDFium in
  `third_party/pdfium/manifest.json`; Gradle and the PDFium workflow derive
  their compatibility checks from that manifest.
- Current Android release artifacts are `arm64-v8a` and `x86_64`; the stroke
  artifact matrix must match the native dependencies that the module actually
  supports.
- GitHub Actions must build from the full source checkout, including
  `third_party`, even though the published npm package will omit source copies.

## Implementation steps

1. Add a manually triggerable or release-triggered workflow dedicated to stroke
   artifacts, using a Linux Android runner and a matrix for each supported ABI.
2. Install the pinned NDK and expose its LLVM tools to the archive producer.
3. Configure and build the producer from Task 1 with tracing/debug
   instrumentation disabled, passing the ABI and source revision. Stage each
   optimized archive with its metadata and license notices under a versioned
   release layout agreed with Task 4.
4. Validate archive format, machine type, API version, required symbols,
   checksum, and deterministic metadata before upload.
5. Run source-linked native tests on the CI host once. For each Android ABI,
   build and link the final consumer or C ABI smoke target against the archive
   without separate Ink/Abseil libraries. Run Android behavior tests only on
   a device/emulator job, if one is provisioned. A failed ABI fails the whole
   workflow; a host-side Android link is not a runtime test.
6. Upload all ABI archives and publish one immutable, clearly named release
   bundle with metadata, license notices, and a checksum manifest. Specify the
   exact release tag/source revision and layout consumed by the staging step
   in Task 4; do not publish a partial ABI set.
7. Support an explicitly requested profiling build with tracing enabled only
   as a separately named temporary artifact. Do not include it in the npm
   package or select it through an implicit debug/release heuristic.

## Ownership and release rules

- CI owns artifact production; consumers never compile third-party source from
  the npm package.
- The archive is platform-specific and must not be presented as an iOS binary.
- The release record must identify the source commit, NDK, ABI, and API version.
- The release record must identify that normal archives have tracing/debug
  instrumentation compiled out.
- License notices for Google Ink and Abseil must accompany the published
  artifact even when their source files are absent from npm.

## Tests and expected results

- Every matrix job produces exactly one valid archive for its ABI.
- Symbol and architecture checks reject an archive built for the wrong target.
- The Android C ABI smoke target links for each ABI; runtime frame/lifecycle
  parity is checked only on a runnable target.
- The workflow fails if any archive, metadata file, checksum, or license notice
  is missing.

## Validation

Validate the workflow locally as far as the host permits with:

```powershell
tools\test-native.ps1 -Suite all -Build
git diff --check -- ':!nitrogen/generated/**'
```

The GitHub-hosted NDK matrix is unavailable locally unless the matching Android
SDK/NDK is installed. Report that limitation rather than substituting a
different NDK for release validation.

## Completion criteria

- CI builds and validates every supported ABI from source.
- Release artifacts include checksums, metadata, and required notices.
- The artifact names, immutable release identity, and layout are ready for
  package staging and Android CMake consumption.

Proposed commit title: `ci: publish verified InkEngine archives`
