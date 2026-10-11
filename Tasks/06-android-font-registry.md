# 06 — Implement Android named font preload and ownership

[Plan index](../TASKS.md)

Status: Planned
Complexity: High
Dependencies: 02, 04

## Objective and non-goals

Implement atomic named-font loading, per-owner source reuse, and cleanup for view/headless owners. Rendering and export use of these fonts belongs to task 08. Do not add remote loading or a global cache.

## Read before editing

- `AndroidFallbackFontResolver.kt`: local/content/resource/Expo android_res source resolution and 64 MiB cap.
- Shared InkSignDocumentOwner and task 01 NamedFontSource/loadFonts signatures.
- `PdfExport.kt`: readOpenTypeFsType and embedding permission checks; `android/src/main/cpp/pdfium_export_jni.cpp`: font resource consumers.
- `CacheArtifactPolicy.kt`: owned temporary artifact allocation/deletion and startup recognition.
- Viewer close/disposal/replacement and headless awaited-close paths.
- Maintainer Android lifecycle/export references; Kotlin/native-module implementation guidance.

## Current behavior to preserve

androidFallbackFont is a separate PDFium source-rendering configuration, resolved once per document. It must not become the named insertion font. New preload applies to both viewer and headless owners and must preserve loaded fonts across viewer document replacement.

## Implementation steps

1. Add `NamedFontRegistry.kt` with case-sensitive name lookup and a normalized-source resource map, owned by InkSignDocumentOwner. Resources retain immutable font bytes, native face/typeface data, and any owned staging file required by supported Android SDKs.
2. Factor local source opening from AndroidFallbackFontResolver into a shared loader without changing its existing remote fallback-font behavior. Named fonts accept local absolute paths/file URIs, content/resource URIs, and packaged Android resource forms already supported; reject network/unknown schemes.
3. Resolve distinct sources on IO once per owner, enforcing the existing 64 MiB per-source cap. Validate static, single-face TrueType outlines, font structure, absence of variable-font tables, and embedding permissions before publication. Native font-validation integration must use loaded bytes rather than rereading source files.
4. Construct a usable Typeface for supported API levels. If a private staging file is required, allocate/register an owned font artifact and recognize it in cache cleanup; never repurpose a caller file.
5. Stage the entire batch before adding names/resources. Same name+normalized source is a no-op; aliases of one source share a resource; name reuse for another source throws font_name_conflict. Failed batches discard newly staged resources and leave prior names untouched. Empty batches are no-ops.
6. Wire viewer/headless loadFonts into each owner's FIFO async queue. Sync registry lookup returns cached immutable resources or font_not_loaded. Actual text use is task 08.
7. Keep registry alive through viewer open replacement. Explicit viewer close, unmount, headless close, and failed owner creation release it only after workers/snapshots finish. No font-name replacement/unload API is introduced.

## Ownership and threading

Registry publication/lookup happens on the owner thread; streams, parsing, staging, and IO remain off the main thread. Close streams on every exit. Resource sharing is owner-local; task 08 export snapshots retain references. File cleanup must participate in awaited headless teardown.

## Tests and expected results

Add NamedFontRegistryInstrumentationTest using bundled static TrueType fixtures and an instrumented source opener. Repeated registrations/aliases read once; batch failure exposes no partial names; prior entries remain usable; conflicting names reject. Missing/corrupt/CFF/collection/variable/nonembeddable fixtures fail at preload. Deleting or changing the original file after preload does not trigger new reads. Verify staging deletion and release after close.

## Validation and completion

Run Android build and `tools\test-android.ps1 -Mode connected -Test com.margelo.nitro.inksignpdf.NamedFontRegistryInstrumentationTest`. Report API/device limitations honestly. The text/export path is not complete until task 08. Complete when both owners share the registry and source-read/publication/cleanup assertions pass.

Proposed commit: `feat(android): preload owner-scoped named fonts`
