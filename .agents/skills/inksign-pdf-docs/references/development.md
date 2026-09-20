## Development rules

- Change authoritative source files, never `nitrogen/generated/**` by hand.
- Public Nitro API source: `src/InkSignView.nitro.ts`, `src/index.ts`, and
  `nitro.json`.
- Android production source is under `android/src/main/java/...`.
- Keep PDF bytes, high-frequency input, and stroke state native; do not add a
  high-frequency JavaScript boundary.
- Keep shared geometry in page coordinates and PDF I/O/export off the UI
  thread.
- Preserve the v1 scope: multi-page PDFs, one active page, page-local history,
  native Android export, source-preserving iOS export, and no Paper/web/
  Windows/macOS implementation.

## Implementation workflow

1. Read the relevant subsystem reference from this skill before editing.
2. Inspect changed-file lists and focused diffs first; use `rg -n` to locate
   symbols and callers before reading bounded source context.
3. Prefer changing interfaces and callers over compatibility layers, aliases,
   silent fallbacks, or swallowed errors.
4. Update the owning maintainer reference when behavior, ownership, scope, or
   validation requirements change. Update `README.md` only for user-facing
   changes.
5. After public Nitro API changes, run `npm run nitrogen`.
6. Validate the narrowest useful layer, then run applicable checks.

Do not expand the v1 contract or introduce another stroke representation
without first documenting the architectural decision in `architecture.md`.

## Native stroke-engine artifacts

The repository keeps the production stroke engine source-linked for desktop,
native tests, and deliberate Android source builds. The Android archive
producer is `tools/build-stroke-engine-archive.ps1`; it uses the Android NDK
toolchain and emits one indexed static archive plus JSON metadata per ABI.
The archive contains the C ABI engine, upstream adapters, Google Ink geometry,
and the required Abseil object files. It does not contain JNI, PDFium, or
`c++_shared`.

`ENABLE_PERFETTO_TRACE=OFF` is the normal archive policy and compiles Android
trace scopes and counters out. A local debug source build may explicitly set
`ENABLE_PERFETTO_TRACE=ON`; a trace-enabled archive is a separately named
profiling artifact and is not the normal release artifact. The producer's
`StrokeEngineArchiveSmoke` target verifies that the merged archive resolves
through `StrokeEngineC.h`; `tools/verify-stroke-engine-archive.ps1` checks the
ABI, metadata, archive members, C ABI symbols, and normal-artifact trace rule.

The manually triggered `.github/workflows/build-and-publish-stroke-engine.yml`
workflow builds the supported Android release ABIs (`arm64-v8a` and
`x86_64`) from a full checkout with NDK `27.1.12297006`. It runs source-linked
native tests once, smoke-links and verifies every ABI, and refuses to reuse an
existing release tag. The release contains raw archives, per-ABI metadata, a
combined manifest, checksums, and Google Ink/Abseil notices. Profiling archives
are never selected by this workflow.

## Validation commands

Use repository runners instead of manually reconstructing their commands:

```powershell
tools\test-android.ps1 -Mode jvm
tools\test-android.ps1 -Mode jvm -Test <fully.qualified.TestClass>
tools\test-android.ps1 -Mode build
tools\test-android.ps1 -Mode connected
tools\test-android.ps1 -Mode connected -Test <fully.qualified.TestClass>
tools\test-native.ps1 -Suite geometry
tools\test-native.ps1 -Suite lifecycle
tools\test-native.ps1 -Suite all
tools\test-ios-lifecycle.ps1
git diff --check -- ':!nitrogen/generated/**'
```

Use `-Build` with `test-native.ps1` only when the selected native targets need
building. Use `-RefreshDependencies` with `test-android.ps1` only when cached
dependencies are insufficient. Android Gradle and ADB commands require the
host execution context; do not claim device validation from an offline build.
Use `-Test` to select one JVM or connected instrumentation class when focused
coverage is sufficient.

For broader repository validation when applicable:

```text
npm run nitrogen
npx tsc --noEmit --pretty false
npm run build
ctest --test-dir build --output-on-failure
```

## Agent polling for long-running runners

The runners capture child-process output and emit bounded failure details plus
a periodic heartbeat. This applies to `test-android.ps1`, `test-native.ps1`,
`capture-trace.ps1`, `check-geometry-contract.ps1`, and `verify-change.ps1`.
Their internal one-second process checks do not require one-second agent
polling.

When a tool returns a live process/session:

- start with an execution wait of about 30 seconds;
- poll the session every 30–60 seconds, never every second;
- cap tool output at roughly 1,000–2,000 tokens; and
- omit `-Verbose` unless command-resolution details are needed.

Use the runner's final `PASS` or `FAIL` line as the result. The heartbeat is
the liveness signal; intermediate polling is not validation.
