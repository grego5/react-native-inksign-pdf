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

Android Gradle consumption, package contents, and source/prebuilt mode are
documented in [the Android native artifacts reference](../android/native-artifacts.md).
