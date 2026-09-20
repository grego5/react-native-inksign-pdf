# Prebuilt stroke-engine distribution plan

This plan packages the Android C++ stroke engine and its Google Ink/Abseil
dependencies as verified per-ABI static archives. The full source repository
continues to build from source for native development and tests, while the
published npm package consumes the prebuilt archives and omits unnecessary
third-party source copies.

Constraints:

- Keep `cpp/StrokeEngineC.h` as the consumer boundary and preserve API version 8.
- Do not change stroke geometry, prediction, ownership, threading, coordinates,
  or the Android frame protocol.
- Keep PDFium packaging and iOS installation working; remove only third-party
  files that the published package no longer needs.
- Release CI produces archives; packaging stages the verified release artifacts
  into the npm tarball before publication. Package consumers do not fetch or
  compile the stroke engine at install time.
- Source mode is an explicit repository-development setting. Missing packaged
  archives are build errors, never a trigger for automatic source fallback.
- Local debug source builds keep Perfetto/debug instrumentation available.
  Published optimized archives compile it out; an explicitly requested
  profiling build is separate and is never the npm default.
- Do not edit generated Nitro output.
- Preserve unrelated existing worktree changes.

## Tasks

1. [Define and produce the bundled stroke archive](Tasks/01-bundled-stroke-archive.md)
2. [Build and publish verified Android artifacts](Tasks/02-stroke-artifact-ci.md)
3. [Consume the archive from Android CMake](Tasks/03-android-prebuilt-consumer.md)
4. [Prune the published package without breaking PDFium](Tasks/04-package-pruning.md)
5. [Verify the packed release and document the distribution contract](Tasks/05-release-verification-and-docs.md)
