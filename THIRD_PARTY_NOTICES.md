# Third-party notices

## Google Ink

The vendored `third_party/google-ink` snapshot provides the upstream
`BrushTipExtruder` geometry closure. It owns the upstream mesh, outline,
constraint, and intersection algorithms behind `cpp/upstream/` for the staged
migration.

The snapshot is Copyright 2024 Google LLC and distributed under the Apache
License 2.0. Its exact revision, closure, and build-only portability patch are
documented in `third_party/google-ink/UPSTREAM.md`; the license text is in
`third_party/google-ink/LICENSE`.

The vendored Abseil dependency is Copyright Google LLC and distributed under
the Apache License 2.0. Its pinned revision and license are documented in
`third_party/abseil-cpp/UPSTREAM.md` and `third_party/abseil-cpp/LICENSE`.

