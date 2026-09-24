## Development rules

- Change authoritative source files, do not edit `nitrogen/generated/**` by hand.
- Public Nitro API source: `src/InkSignView.nitro.ts`, `src/index.ts`, and `nitro.json`.
- Android production source is under `android/src/main/java/...`.
- Prioritize correct, streamlined architecture over narrow patches and defensive
  checks that conceal implementation mistakes; internal breaking changes are acceptable.
- Treat existing tests and documentation as descriptions to revise, not constraints
  on a better design.
- For cross-language changes, report ownership, lifetime, threading, data
  representation, and error translation.

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
7. Automated tests should be added for stable, observable contracts and meaningful regressions.
   Validate visual, geometric, timing, and interaction quality through representative
   real-world use and inspection. Keep the test suite focused on checks that provide
   reliable confidence.

## iOS validation

- Run the narrowest simulator focus for native behavior. Use a device archive
  for integration; visual fidelity and interaction still need runtime checks.
- For PDF changes, fixture-check visible content and geometry, locked text and
  vector signatures, write/reopen, and external-viewer interoperability.
  Advanced source PDF semantics are outside the editing contract.

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
