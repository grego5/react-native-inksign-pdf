## Development instructions

- Change authoritative source files, do not edit `nitrogen/generated/**` by hand.
- Public contracts: `src/InkSignTypes.ts`; native specs:
  `src/InkSignDocument.nitro.ts` and `src/InkSignView.nitro.ts`; React entry point:
  `src/index.ts`; codegen configuration: `nitro.json`.
- Android production source is under `android/src/main/java/...`.
- Prioritize correct, streamlined architecture over narrow patches and defensive
  checks that conceal implementation mistakes; internal breaking changes are acceptable.
- Follow this validation boundary map: public React arguments in `src/index.ts`;
  touch and gesture input at platform handlers; PDF, image, and OS data at their
  loaders; state-dependent commands at the owning native operation before
  mutation.
- Before adding, moving, or removing a guard, inspect the relevant reference and
  trace only the changed value's paths to its boundary. Validate there; do not
  duplicate checks downstream. Types and expected callers are not proof. If the
  boundary is unclear, treat the value as untrusted and establish its ingress
  before changing the guard.
- Downstream code relies on admitted values. Assert impossible internal states
  instead of hiding logic defects with defensive gates. Test observable
  behavior, not straightforward guard predicates or impossible states.
- Treat existing tests and documentation as descriptions to revise, not constraints
  on a better design.
- For cross-language changes, report ownership, lifetime, threading, data
  representation, and error translation.

## Source naming

- Shared data contracts live in `InkSignTypes.ts`; Hybrid Object/View specs live
  in the corresponding `.nitro.ts` files. Public exports come from `index.ts`.
- `ViewerCanvas` owns presentation and input on both platforms. Android extension
  files use `ViewerCanvas<Topic>.kt`. The low-latency renderer uses Android's framework
  `SurfaceView` independently.
- Both platforms use `DocumentCoordinator`, `PreparedPage`, `ProjectedPage`,
  `PageContentHistory`, `ViewerDocumentState`, `ImagePageEncoder`, and
  `PdfiumExporter` as role names; Swift types retain their `InkSignPdf` prefix.
- Swift viewer extensions use `ViewerCanvas+<Topic>.swift`. Coordinator page
  transactions live in `DocumentCoordinator+PageTransactions.swift`; committed
  state, text targets, and page history have separate source files.
- `CommittedDocumentState.swift` owns the internal committed document model;
  Nitrogen's `DocumentState.swift` defines the public state snapshot.
- Production C++ bridge files use PascalCase names matching their role, such as
  `PdfiumRenderJni.cpp` and `NitroAdapter.cpp`. Shared C++ lives under `core/`.

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
7. Automated tests should cover stable, observable contracts and meaningful
   regressions. Do not add tests that merely repeat straightforward boundary
   guard predicates or target impossible internal states. Validate visual,
   geometric, timing, and interaction quality through representative real-world
   use and inspection. Keep the test suite focused on checks that provide
   reliable confidence.

## iOS validation

- Run the narrowest simulator focus for native behavior. Use a device archive
  for integration; visual fidelity and interaction still need runtime checks.
- For PDF changes, fixture-check source preservation, text/vector placement,
  write/reopen, and external-viewer interoperability.
  Advanced source PDF semantics are outside the editing contract.

### Run iOS tests

The external `vmac` adapter owns Mac orchestration and the `inksignpdf` profile.
The profile contains its test/build scripts, Podfile helper, and log/publish tools;
these scripts are maintained outside this source repository.

```powershell
vmac test inksignpdf DocumentCoreTests
vmac test inksignpdf DocumentCoreTests/testEmptyDocumentPopulatesAnAttachedViewerAndSurvivesDetach
vmac test inksignpdf --build-only
vmac log inksignpdf
```

Omit selectors to run the configured test scheme. `--build-only` invokes Xcode
`build-for-testing`, producing test artifacts without an IPA. Runs snapshot tracked
and nonignored untracked source into a Git bundle, verify the Mac checkout, and
hold one checkout lock through execution and cleanup. Global machine environment
settings use manually installed tooling; project setup is owned by the profile.

The MCP exposes `run_tests({project: 'inksignpdf', tests: ['DocumentCoreTests']})`,
`status`, `logs`, and `cancel`. `buildOnly: true` builds test artifacts. IPA archive,
export, and publishing are CLI-only and are not exposed as MCP actions.

Record snapshot ID, test counts, `testOutcome`, and `runnerTermination` separately.
Xcode can report results before its process exits. A zero-test result or successful
build alone does not establish behavior.

### Fallback: run iOS tests on GitHub Actions

- When the local Mac VM is unavailable, use the repository's iOS workflow on a
  GitHub-hosted macOS runner and select the narrowest focus for the change.

### Publish an iOS ad hoc IPA

Use the external adapter from Windows:

```powershell
vmac build inksignpdf
vmac build inksignpdf --publish
vmac publish inksignpdf --run <successful-build-run-id>
vmac publish inksignpdf --ipa C:\path\app.ipa
```

Builds archive and export using manually configured signing certificates, an
unlocked keychain, and a matching provisioning profile on the Mac. `--publish`
runs the profile's local publisher only after a successful IPA build. Publishing
requires GitHub CLI authenticated with repository write access. Machine paths and
profile scripts are configured outside this repository.

## Run Android tests and builds locally

Use repository runners instead of manually reconstructing their commands:

```powershell
tools\test-android.ps1 -Mode jvm
tools\test-android.ps1 -Mode jvm -Test <fully.qualified.TestClass>
tools\test-android.ps1 -Mode build
tools\test-android.ps1 -Mode build -Abi x86_64
tools\test-android.ps1 -Mode connected -Abi x86_64
tools\test-android.ps1 -Mode connected
tools\test-android.ps1 -Mode connected -Test <fully.qualified.TestClass>
tools\test-native.ps1 -Suite geometry
tools\test-native.ps1 -Suite lifecycle
tools\test-native.ps1 -Suite all
git diff --check -- ':!nitrogen/generated/**'
```

Build and connected modes default to `arm64-v8a`. Select `x86_64`
with `-Abi` if necessary.

Use `-Build` with `test-native.ps1` only when the selected native targets need
building. Use `-RefreshDependencies` with `test-android.ps1` only when cached
dependencies are insufficient. Android Gradle and ADB commands require the
host execution context; do not claim device validation from an offline build.
Use `-Test` to select one JVM or connected instrumentation class when focused
coverage is sufficient.

For broader repository validation when applicable:

```text
npm run nitrogen
npm run test:public-api
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
