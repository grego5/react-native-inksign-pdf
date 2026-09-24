# Native InkEngine artifacts

The repository keeps the production InkEngine source-linked for desktop,
native tests, and deliberate Android source builds. The Android archive
producer is `tools/build-ink-engine-archive.ps1`; it uses the Android NDK
toolchain and emits one indexed archive plus JSON metadata per ABI.
The archive contains the C ABI engine, upstream adapters, Google Ink geometry,
and the required Abseil object files. It does not contain JNI, PDFium, or
`c++_shared`.

`ENABLE_PERFETTO_TRACE=OFF` is the normal archive policy and compiles Android
trace scopes and counters out. A local debug source build may explicitly set
`ENABLE_PERFETTO_TRACE=ON`; a trace-enabled archive is a separately named
profiling artifact and is not the normal release artifact. The producer's
`InkEngineArchiveSmoke` target verifies that the merged archive resolves
through `InkEngineC.h`; `tools/verify-ink-engine-archive.ps1` checks the
ABI, metadata, archive members, C ABI symbols, and normal-artifact trace rule.

The manually triggered `.github/workflows/build-and-publish-ink-engine.yml`
workflow builds the supported Android release ABIs (`arm64-v8a` and
`x86_64`) from a full checkout with NDK `27.1.12297006`. It runs source-linked
native tests once, smoke-links and verifies every ABI, and refuses to reuse an
existing release tag. The release contains raw archives, per-ABI metadata, a
combined manifest, checksums, and Google Ink/Abseil notices. Profiling archives
are never selected by this workflow.

Android Gradle consumes the pinned release in `android/ink-engine-release.json`.
In prebuilt mode, `prepareInkEngine` downloads the single
`ink-engine-1.0.0-android-static.zip` release asset when the verified cache is
missing, validates its pinned ZIP/checksum hashes, inner manifest, per-ABI
metadata and archives, then installs the selected archives under
`android/build/ink-engine/<abi>/` before CMake configuration. A valid cache is
reused offline. CMake performs the final ABI, API version, expected NDK, byte
size, SHA-256, and trace-disabled checks before linking the imported target.
Repository development and tests explicitly opt into source mode with
`ReactNativeInkSignPdf_useSourceInkEngine=true`; source mode remains the only
Android path that compiles Google Ink and Abseil from `core/third_party` and does
not invoke the InkEngine downloader. The npm package contains the release pin,
C ABI headers, and PDFium inputs, but no InkEngine archives or Google
Ink/Abseil source trees.
