# Abseil dependency snapshot

This directory contains Abseil commit
`5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a` (tag `20260526.0`) from
`https://github.com/abseil/abseil-cpp.git`, under the Apache License 2.0 in
[`LICENSE`](LICENSE).

It is pinned because the Google Ink geometry closure requires the current
status macros and builder APIs. The desktop and mobile build integrations use
the upstream CMake targets and semantics; no local compatibility stubs or
behavioral substitutions are used. The iOS podspec consumes the explicit
production source list in `IOS_PRODUCTION_SOURCES.txt`; it does not compile
tests, benchmarks, or Windows-only sources.
