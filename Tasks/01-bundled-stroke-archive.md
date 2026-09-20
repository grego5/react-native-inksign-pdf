# Define and produce the bundled stroke archive

Back to [TASKS.md](../TASKS.md).

Status: Planned

## Objective

Produce one Android static archive per ABI containing every non-platform
stroke-engine source currently compiled by `android/CMakeLists.txt`, its
upstream adapters, Google Ink geometry, and all required Abseil objects. The
archive must be consumable through the existing C ABI without requiring Google
Ink or Abseil source, headers, or separate archives in the consumer project.

## Non-goals

- Do not change stroke behavior, geometry, prediction, or frame encoding.
- Do not replace the source-built desktop/native test configuration.
- Do not bundle `c++_shared`, Android system libraries, PDFium, or JNI code.
- Do not expose the C++/STL implementation as a public consumer API.
- Do not include Perfetto tracing or optional debug instrumentation in the
  published optimized archive.

## Read before editing

- `CMakeLists.txt`: `UpstreamStrokeGeometry`, `UpstreamStrokeOutput`,
  `StrokeEngine`, and native test targets.
- `android/CMakeLists.txt`: current Android source list and transitive native
  link dependencies.
- `cpp/StrokeEngineC.h`: `NSE_STROKE_ENGINE_API_VERSION`, opaque handle,
  borrowed frame lifetime, and C data layout.
- `.agents/skills/inksign-pdf-docs/references/stroke-engine/replay-validation.md`:
  production-engine and replay-test invariants.
- `.agents/skills/inksign-pdf-docs/references/development.md`: source-of-truth
  and native validation rules.

## Current behavior and invariants

- Desktop CMake builds Google Ink and Abseil from `third_party`, then builds
  the source targets and native tests.
- Android CMake currently compiles the stroke engine and upstream adapter
  sources directly into `ReactNativeInkSignPdf`.
- `StrokeEngineC.h` is the stable platform-facing boundary; returned frame
  pointers are borrowed until the next mutating call.
- The engine is synchronous and caller-owned. It remains page-space and
  toolkit-neutral.

## Implementation steps

1. Inventory the Android target's source list and classify each entry. Put
   `cpp/StrokeEngine*`, `cpp/engine`, `cpp/input`, `cpp/modeling`, and
   `cpp/upstream` production implementations in the archive, plus Google Ink
   geometry and the Abseil objects they need. Leave `android/src/main/cpp`
   JNI/platform code and `cpp/pdfium` outside it. Reconcile this inventory
   against the desktop CMake targets before removing any consumer sources.
2. Add a reproducible producer configuration that accepts an Android ABI,
   toolchain, and trace policy. Build the same C++20 source with
   release-compatible flags and emit a normal indexed static archive.
   Published archives set `ENABLE_PERFETTO_TRACE=OFF`; local debug source
   builds set it to `ON`. Preserve object-file granularity so final linker
   dead stripping remains possible.
3. Emit machine-readable metadata beside each archive: ABI, NDK/toolchain,
   source revision, API version, byte size, and SHA-256.
4. Validate the archive with the Android LLVM tools: check the expected ELF
   machine, archive members, required C API implementation symbols, and
   metadata. Unresolved cross-member references inside a static archive are
   normal; require a final Android shared-library or C ABI smoke **link** that
   resolves them without separate Google Ink/Abseil archives.
5. Keep runtime behavior checks in host-native source-linked tests and, when
   available, Android device/emulator tests. Do not claim that Android objects
   linked on the build host were executed there. Compare final, prediction,
   replacement, cancellation, and borrowed-frame behavior on a runnable target.

## Ownership and build rules

- The archive contains implementation code only; platform adapters retain
  ownership of JNI buffers and copy borrowed frame data before the next engine
  mutation.
- Do not add a JavaScript boundary or alter high-frequency input flow.
- Keep `CMakeLists.txt` source-linked so contributors can build and test the
  production engine without downloaded release artifacts.
- Any generated artifact metadata must be derived from the source revision and
  must not be hand-edited into generated Nitro output.
- Apply the compile-time trace policy to shared engine code and Android adapter
  trace scopes/counters. A runtime Perfetto session cannot re-enable tracing
  that was compiled out.

## Tests and expected results

- Existing native C API tests continue to pass unchanged.
- The per-ABI Android smoke target links the C ABI without separate Ink/Abseil
  libraries. A runnable test creates an engine, configures a pen, exercises
  prediction replacement, ends a real stroke, and observes a final frame.
- The archive inspection rejects the wrong ABI, missing symbols, bad API
  version metadata, or a failed final link caused by missing dependencies.
- The normal archive has no unresolved Android trace symbols. A profiling
  archive with tracing enabled is explicitly named and never substituted for
  the normal release archive.

## Validation

```powershell
tools\test-native.ps1 -Suite all -Build
git diff --check -- ':!nitrogen/generated/**'
```

If the required Android NDK or LLVM archive tools are unavailable, record the
exact missing tool and leave the CI validation step as the authoritative check;
do not weaken the archive contract.

## Completion criteria

- A local producer can create a self-contained archive for each supported ABI.
- The archive links through `StrokeEngineC.h` without Google Ink/Abseil inputs.
- Source-based native tests remain available and pass.

Proposed commit title: `build: bundle stroke engine native dependencies`
