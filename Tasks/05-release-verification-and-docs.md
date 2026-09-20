# Verify the packed release and document the distribution contract

Back to [TASKS.md](../TASKS.md).

Status: Planned

## Objective

Prove that the packed npm artifact uses the bundled stroke engine, then update
maintainer and user-facing documentation to describe the source/prebuilt split.

## Non-goals

- Do not change stroke algorithms or platform behavior.
- Do not claim iOS uses the shared C++ engine; it continues to use PencilKit.
- Do not describe the optimized npm archive as trace-enabled by default.
- Do not mark validation complete when Android, macOS, or release-only tooling
  was unavailable.

## Read before editing

- `AGENTS.md`: repository entry-point requirements.
- `.agents/skills/inksign-pdf-docs/references/development.md`: validation
  commands and documentation ownership.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`: current C++
  engine ownership, threading, and Android-only usage.
- `.agents/skills/inksign-pdf-docs/references/stroke-engine/replay-validation.md`:
  production replay and geometry invariants.
- `README.md`: user-facing native dependency and platform documentation.
- `tools/test-native.ps1`, `tools/test-android.ps1`, and
  `tools/test-ios-lifecycle.ps1`: repository validation entry points.

## Current behavior and invariants

- Native replay uses the production stroke engine; it is not a second geometry
  implementation.
- The engine is synchronous, caller-owned, toolkit-neutral, and page-space.
- Android uses the shared C++ outline engine; iOS uses PencilKit.
- The repository requires final `git diff --check` and reports unavailable
  platform toolchains instead of weakening contracts.

## Implementation steps

1. Stage the exact verified release artifacts from Task 4, create a temporary
   npm tarball, and install it in an isolated consumer directory. Do not expose
   the repository's Google Ink/Abseil source tree or preexisting build outputs.
2. Build the installed Android module in prebuilt mode for every supported ABI.
   Run host-native tests separately, plus JVM and a representative connected
   instrumentation or release-build check when the environment supports them.
   Do not describe a cross-linked Android target as executed.
3. Where an Android device/emulator is available, run equivalent source-mode
   and prebuilt-mode C ABI/replay cases there and compare lifecycle statuses,
   final contours, prediction replacement, cancellation, and frame revisions.
   Host-native source-linked results alone cannot establish Android archive
   runtime parity. Fail on any mismatch and record unavailable runtime coverage.
4. Inspect the actual tarball and final Android link inputs: verify the complete
   ABI archive set, matching release metadata/checksums, no source fallback,
   and no accidental Google Ink/Abseil source inclusion. Confirm PDFium paths
   and iOS postinstall/pod paths still resolve from the installed package.
5. Update the owning maintainer references with the current artifact contract,
   supported ABI/NDK matrix, source-build fallback, and validation command.
6. Update `README.md` only with user-facing installation/build implications.
   Keep licenses and release metadata authoritative rather than duplicating
   mutable checksum details in prose.

## Ownership and documentation rules

- Documentation must describe current behavior, not workflow history.
- Do not modify generated Nitro output to document the packaging change.
- Preserve all engine lifecycle, threading, coordinate, and prediction
  invariants while changing only distribution mechanics.
- Keep existing unrelated worktree changes intact.

## Tests and expected results

- Packed-package Android build succeeds without Google Ink/Abseil source files.
- Android source and archive modes produce identical representative frames when
  both can be executed on the same Android runtime.
- The normal archive has tracing/debug instrumentation compiled out, while the
  local debug source configuration can emit Perfetto events when explicitly
  enabled.
- `npm pack --dry-run` and license checks pass.
- Documentation accurately states Android prebuilt consumption and source-build
  availability.

## Validation

```powershell
tools\test-native.ps1 -Suite all -Build
tools\test-android.ps1 -Mode jvm
tools\test-android.ps1 -Mode build
npm pack --dry-run
npx tsc --noEmit --pretty false
git diff --check -- ':!nitrogen/generated/**'
```

Run `tools\test-ios-lifecycle.ps1` on macOS when iOS packaging paths change.
If a platform toolchain is unavailable, report the command and environment
instead of substituting an unvalidated result.

## Completion criteria

- The packed npm artifact is independently buildable through the prebuilt path.
- Source and prebuilt paths have parity coverage for the C ABI and geometry.
- Maintainer and user-facing documentation describe the final distribution
  behavior and validation boundaries.

Proposed commit title: `docs: document prebuilt stroke engine distribution`
