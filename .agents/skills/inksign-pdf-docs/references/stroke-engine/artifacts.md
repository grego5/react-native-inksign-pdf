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

`.github/workflows/build-and-publish-ink-engine.yml` publishes verified
`arm64-v8a` and `x86_64` archives with NDK `27.1.12297006` and tracing disabled.
It builds and tests sources or republishes retained artifacts from a successful
run, preserving their source revision. Existing releases cannot be overwritten.
Reassembled ZIP and checksum assets must match the pins in
`android/ink-engine-release.json`.

Android Gradle consumption, package contents, and source/prebuilt mode are
documented in [the Android native artifacts reference](../android/native-artifacts.md).
