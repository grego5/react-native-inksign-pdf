# Consume the archive from Android CMake

Back to [TASKS.md](../TASKS.md).

Status: Complete

## Objective

Make the published Android module link the per-ABI bundled stroke archive while
retaining an explicit source-build path for repository development and tests.

## Non-goals

- Do not alter the JNI adapter, Kotlin `StrokeEngine`, frame codec, or input
  batching protocol except where an include or link target must change.
- Do not change PDFium download, validation, or lifecycle behavior.
- Do not introduce a shared stroke-engine `.so` unless static linking proves
  impossible; the target design is one archive linked into the module `.so`.
- Do not make a debug app depend on a tracing-enabled published archive. Local
  debug tracing uses explicit source mode or a separately requested profiling
  artifact.

## Read before editing

- `android/CMakeLists.txt`: `ReactNativeInkSignPdf`, PDFium imported target,
  current Google Ink subdirectories, and source file list.
- `android/src/main/cpp/StrokeEngine.cpp`: JNI adapter calls into the C ABI and
  copies borrowed frame data.
- `android/src/main/cpp/StrokeEngine.hpp`: JNI-facing declarations and include
  ownership.
- `android/build.gradle`: ABI filters, `c++_shared`, CMake arguments, and NDK
  compatibility checks.
- `cpp/StrokeEngineC.h`: public archive header and frame pointer lifetime.
- `Tasks/01-bundled-stroke-archive.md`: imported archive contract.

## Current behavior and invariants

- Android CMake consumes one verified archive per ABI from
  `android/stroke-engine/<abi>/` by default. Explicit source mode adds the
  Google Ink and Abseil source directories and compiles the same stroke-engine
  implementation files into `ReactNativeInkSignPdf`.
- The JNI adapter remains the only platform bridge for the engine. Java/Kotlin
  receives copied frame bytes, never archive-owned pointers.
- High-frequency input stays native and synchronous; no JavaScript calls are
  introduced.
- PDFium remains an imported static archive with its existing ABI validation.

## Implementation steps

1. Add an explicit CMake source-build option, defaulting to prebuilt. The
   repository's development/test invocation sets source mode deliberately;
   package consumers use the default. Never infer source mode from the presence
   or absence of `third_party` or an archive.
2. Define an imported static target whose location is selected by `ANDROID_ABI`
   under `android/stroke-engine/<abi>/`; the JNI adapter retains the local
   include surface and the archive is linked through the C ABI.
3. Remove from the prebuilt target every implementation source inventoried in
   Task 1 and the Google Ink/Abseil `add_subdirectory` calls. Keep JNI and
   PDFium sources in the platform target; keep source mode complete and
   independent.
4. Link the imported archive into `ReactNativeInkSignPdf` alongside PDFium,
   Android libraries, and `c++_shared`.
5. Add configure-time failures for a missing archive, unsupported ABI, missing
   metadata, or API-version mismatch. Verify the staged ABI/NDK identity,
   recorded size, and checksum before linking. Never switch to source mode
   implicitly.
6. Apply the same trace compile definition to adapter-side
   `ScopedPerfettoTrace` calls, then confirm that JNI frame-copy behavior and
   all existing native library symbols remain unchanged.

## Ownership and lifecycle rules

- The archive is immutable implementation code. `JStrokeEngine` owns the
  opaque engine handle and destroys it exactly once.
- Prebuilt mode is the default. Repository development and tests explicitly
  opt into source mode with `ReactNativeInkSignPdf_useSourceStrokeEngine=true`;
  the example project enables that property for local builds.
- Frame pointers remain valid only until the next mutating engine call; the
  adapter must continue copying them before mutation.
- Android generation, page ownership, prediction replacement, and disposal
  remain unchanged.
- Do not edit `nitrogen/generated/**` by hand.

## Tests and expected results

- A packaged Android build links successfully for every supported ABI without
  Google Ink or Abseil source directories, or any source-mode fallback.
- Existing `StrokeFrameCodec`, prediction, front-buffer, and instrumentation
  tests pass unchanged.
- Source mode still builds the native C++ tests and produces the same geometry
  fixtures as prebuilt mode.
- A local debug source build can emit Perfetto events when explicitly enabled;
  the normal prebuilt archive does not reference Android trace symbols.

## Validation

```powershell
tools\test-native.ps1 -Suite all -Build
tools\test-android.ps1 -Mode jvm
tools\test-android.ps1 -Mode build
git diff --check -- ':!nitrogen/generated/**'
```

If Android SDK/NDK execution is unavailable, report the exact unavailable
toolchain and leave the GitHub artifact matrix as the release gate.

## Completion criteria

- Published-package configuration imports exactly one correct archive per ABI.
- Archive metadata, ABI, API version, expected NDK, size, checksum, and the
  normal trace-disabled policy are checked at CMake configure time.
- Repository source mode remains functional.
- No high-frequency boundary, frame lifetime, or lifecycle invariant changes.

Proposed commit title: `android: consume prebuilt stroke engine archive`
