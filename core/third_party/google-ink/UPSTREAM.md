# Google Ink geometry snapshot

This directory contains the Google Ink source snapshot for module version
`1.1.0`. The vendored source content is pinned by the SHA-256 manifest in
[`SOURCES.sha256`](SOURCES.sha256) and distributed under the Apache License 2.0
in [`LICENSE`](LICENSE).

`CMakeLists.txt` compiles only the `BrushTipExtruder` dependency closure:
geometry, mesh, outline, intersection, constraint, and the required stroke
types. Rendering, JNI, particle-brush, brush behavior, and platform stacks are
not included.

The only source divergence is a build-only MSVC portability patch in
`ink/geometry/quad.h`: the private constructor is no longer `constexpr` because
MSVC rejects the upstream constexpr evaluation of `Angle::Normalized()`. The
algorithm and runtime behavior are unchanged. `legacy_vertex.h` is an exact
closure source from the same snapshot.

The closure uses the vendored Abseil commit recorded in
`../abseil-cpp/UPSTREAM.md`; it is linked statically through maintained CMake
targets. No build reads source from `.codex`.
