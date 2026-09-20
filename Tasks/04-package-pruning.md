# Prune the published package without breaking PDFium

Back to [TASKS.md](../TASKS.md).

Status: Planned

## Objective

Stage the verified stroke release artifacts into the npm package and omit
Google Ink/Abseil source copies, while retaining all metadata, headers,
binaries, and scripts required for Android PDFium and iOS pod installation.

## Non-goals

- Do not delete `third_party` from the Git repository.
- Do not remove required PDFium headers, manifest data, licenses, or pinned
  binary validation.
- Do not change iOS rendering architecture or make iOS consume the Android
  stroke engine.
- Do not modify unrelated existing changes in the podspec or iOS cache policy.

## Read before editing

- `package.json`: npm `files` allowlist, especially `third_party` and native
  source entries.
- `android/build.gradle`: PDFium manifest path, archive download, extraction,
  and checksum validation.
- `android/CMakeLists.txt`: PDFium include path and imported archive path.
- `tools/fetch-pdfium-ios.mjs`: manifest path and iOS artifact download flow.
- `ReactNativeInkSignPdf.podspec`: source files, PDFium framework, preserved
  paths, and pod integration.
- `THIRD_PARTY_NOTICES.md`: required notices for retained and prebuilt code.
- `Tasks/03-android-prebuilt-consumer.md`: package layout expected by CMake.

## Current behavior and invariants

- `package.json` currently publishes the entire `third_party` tree.
- Android and iOS PDFium support currently reads metadata from
  `third_party/pdfium/manifest.json` and Android compiles against headers under
  `third_party/pdfium/include`.
- The iOS postinstall script exits on non-macOS but must continue downloading
  and validating the pinned XCFramework on macOS.
- npm packaging is allowlist-based, so removing an entry can break runtime
  scripts even when the repository build still succeeds.

## Implementation steps

1. Define one stable package path for the per-ABI stroke archives, metadata,
   and notices. Add a publish/staging step that retrieves the immutable release
   identified in Task 2, verifies its checksum manifest and source/NDK/API/ABI
   metadata, and copies the complete ABI set there before `npm pack`. Fail on
   missing or mismatched artifacts; do not download stroke code at consumer
   install time.
2. Replace the broad `third_party` npm allowlist entry with only
   `third_party/pdfium` and verify that its existing manifest/include paths
   work from the packed package. Move those paths only if pack/install proves
   the narrow allowlist insufficient; update all consumers if moved.
3. Add the staged stroke archives, metadata, C ABI header, and required license
   files to the allowlist. Confirm no Google Ink/Abseil source or private
   headers are included.
4. Keep the repository’s full `third_party` tree for source builds and CI.
   Ensure the podspec and iOS postinstall still find PDFium after packing.

## Packaging and ownership rules

- The npm tarball is a consumer artifact, not the source-of-truth checkout.
- Do not ship private Google Ink/Abseil headers because the consumer links the
  bundled archive through the C ABI.
- Preserve all third-party license notices for code compiled into the archive.
- Avoid broad globs that accidentally re-add source trees to the tarball.

## Tests and expected results

- Staging rejects an absent ABI, invalid hash, or mismatched release identity.
- `npm pack --dry-run` lists the prebuilt archive for every supported ABI.
- The tarball contains no Google Ink or Abseil source directories.
- PDFium Android Gradle validation still downloads/checksums the expected
  archives.
- macOS postinstall and pod integration still locate the iOS PDFium artifact.

## Validation

```powershell
npm pack --dry-run
npm run verify:pdfium
tools\test-android.ps1 -Mode build
git diff --check -- ':!nitrogen/generated/**'
```

macOS-only iOS checks may be unavailable on this host. Report that limitation
and preserve the existing `tools\test-ios-lifecycle.ps1` validation for a
macOS runner.

## Completion criteria

- Published npm output contains the verified complete archive set and omits
  Google Ink and Abseil source copies.
- PDFium Android and iOS package flows remain intact.
- All binary and third-party notice files required by consumers are present.

Proposed commit title: `package: omit native third-party source copies`
