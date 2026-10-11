# Headless documents and named custom fonts

This plan implements the agreed headless PDF/image workflow and named, preloaded fonts shared with the viewer. Android implementation is in place and compiles. Runtime tests were skipped at user direction. iOS ownership, headless, and font tasks are deferred until the PDFium migration; only shared-interface signature adaptations are present on iOS.

## Contract and constraints

- Headless: open, page metadata, analysis/text editing, explicit page append/remove/move/rotate, export, deterministic close. No UI, picker, viewer state, or public undo/redo.
- Fonts: `loadFonts([{ name, uri }])`, followed by synchronous text operations with a named font. Value setters accept optional shared text options atomically.
- Static single-face TrueType fonts only, including OpenType containers with TrueType outlines. Invalid/unregistered fonts throw. Missing glyphs permit Android system fallback in the editor and API 31+ export; older custom-font export uses the selected font's missing-glyph appearance. Named-font loading/shaping failures remain explicit.
- Cache each local/bundled font source once per document/view owner. Keep resources through export; release on close/unmount. No global font cache.
- Template-owned rectangles control centering and line limits. Preserve existing coordinate, rotation, text lookup, and source-text fallback contracts.
- Source files remain unchanged. Returned headless exports survive close and are caller-owned temporary cache files. Preserve visible signatures/supported annotations; cryptographic signature validity is outside scope.

Follow [AGENTS.md](AGENTS.md) and [.agents/skills/inksign-pdf-docs/SKILL.md](.agents/skills/inksign-pdf-docs/SKILL.md). Read bounded context using each task's lookup map. Do not edit generated files by hand.

## Execution order

Tasks 01, 02, 04, 06, 08, and 10 are implemented for Android. Task 11 documentation and compile checks are complete; runtime acceptance remains unverified. Tasks 03, 05, 07, and 09 are deferred by the Android-only scope.

| Task | Outcome | Dependencies |
| --- | --- | --- |
| [01 — Native and public contracts](Tasks/01-establish-contracts.md) | Authoritative Nitro types and generated interfaces | None |
| [02 — Android document ownership](Tasks/02-android-document-owner.md) | Shared document/text service with viewer regression protection | 01 |
| [03 — iOS document ownership](Tasks/03-ios-document-owner.md) | Shared document/text service with viewer regression protection | 01 |
| [04 — Android headless documents](Tasks/04-android-headless-document.md) | Headless lifecycle, indexed page operations, export ownership | 02 |
| [05 — iOS headless documents](Tasks/05-ios-headless-document.md) | Headless lifecycle, indexed page operations, export ownership | 03 |
| [06 — Android font registry](Tasks/06-android-font-registry.md) | Atomic preload, source deduplication, scoped resources | 02, 04 |
| [07 — iOS font registry](Tasks/07-ios-font-registry.md) | Atomic preload, source deduplication, scoped resources | 03, 05 |
| [08 — Android font-aware text/export](Tasks/08-android-custom-font-text.md) | Shared custom-font editing, layout, and PDF embedding | 06 |
| [09 — iOS font-aware text/export](Tasks/09-ios-custom-font-text.md) | Shared custom-font editing, layout, and PDF appearance | 07 |
| [10 — Validated JavaScript API](Tasks/10-public-api-facades.md) | Exported headless facade and shared viewer validation | 04–09 |
| [11 — Integration and documentation](Tasks/11-integration-and-documentation.md) | Cross-platform acceptance evidence and public documentation | 10 |

The two platform sequences have independent dependencies; this index does not authorize agent delegation.

## Intermediate integration and completion

Task 01 changes generated native signatures. Native compilation can remain incomplete until the affected platform's tasks through 08 or 09 are complete; the JavaScript facade is complete in 10. Record expected missing integrations precisely. Do not add dummy implementations, claim a failing build passed, or treat these intermediate states as shippable.

Each task specifies focused acceptance tests and commands. Run full applicable integration checks in 11. Update task status only after its outcome is implemented and its verification evidence or unavailable-environment limitations are recorded. This plan itself requires no native build or generated-code changes.
