# 07 — Implement iOS named font preload and ownership

[Plan index](../TASKS.md)

Status: Planned
Complexity: High
Dependencies: 03, 05

## Objective and non-goals

Implement atomic named-font preload and owner-scoped native font resources on iOS. Text layout/appearance use belongs to task 09. Do not globally register fonts or introduce remote font fetching.

## Read before editing

- Shared InkSignDocumentOwner and task 01 NamedFontSource/loadFonts contracts.
- `ios/TextRendering.swift`: InkSignPdfTextStyle font/attributes; `TextState.swift`: annotation options/content.
- `ios/PageInputCoordinator.swift`: localURL and file ingress; cache artifact policy and close/disposal paths.
- Maintainer Swift lifecycle/export references and native-module/Swift implementation skills.
- Existing text/export tests for fixture and framework setup.

## Current behavior to preserve

iOS currently uses system fonts. Source fallback-font settings are Android-only. Main-thread state and serial PDF-queue ownership must remain explicit; font sources are caller-owned.

## Implementation steps

1. Add `ios/NamedFontRegistry.swift` owned by the shared document owner, with exact name lookup and normalized local-source deduplication.
2. Read absolute local paths/file URIs, including resolved application-bundle file URIs, off the main thread. Reject HTTP(S) and unsupported schemes. Keep caller files unchanged and close file access on every exit.
3. Validate loaded bytes as static, single-face TrueType-outline fonts, enforce the same 64 MiB cap and embedding-permission rules as Android, and reject CFF/collections/variable/corrupt data with invalid_font. Reuse loaded bytes for all subsequent native font construction.
4. Retain immutable Data/provider/CGFont and CoreText resources scoped to the owner. Establish the UIFont/attributed-text integration supported by the current iOS toolchain using a focused native compile/test; do not introduce process-global CTFontManager registration as a shortcut.
5. Publish names only after the full batch loads and validates. Identical name/source is a no-op; aliases share resources; conflicting name/source rejects. Failed batches release new candidates and preserve all prior registrations; empty arrays are no-ops.
6. Wire loadFonts into viewer/headless FIFO commands. Synchronous lookup returns a resource or font_not_loaded; later rendering/task 09 uses that resource directly.
7. Preserve registrations through viewer document replacement. Close/unmount/headless teardown release resources after active worker users finish. Await cleanup in headless close.

## Ownership and threading

Font resources are immutable native values; registry mutation is owner-thread-only. Snapshot references keep resources alive during asynchronous export. Headless/JS page handles must not independently retain the font registry beyond close. No URI reads occur in synchronous text setters.

## Tests and expected results

Add NamedFontRegistryTests with a bundled TrueType fixture and injectable/countable source reads. Assert one read across duplicate loads/aliases, atomic failed batches, conflicts, unsupported format/permission failures, and continued use after the source disappears. Test two owners are independent and close releases providers/font resources after worker users finish.

## Validation and completion

Run the hash-verified Mac runner with IOS_TEST_ONLY selecting NamedFontRegistryTests. The native UIFont integration must compile and be exercised; if unavailable, record it as an unresolved verification step rather than claiming feasibility from type names. Custom text output remains incomplete until task 09. Complete when both owners use scoped, atomic registries and lifecycle assertions pass.

Proposed commit: `feat(ios): preload owner-scoped named fonts`
