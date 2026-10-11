# 01 — Establish native and public contracts

[Plan index](../TASKS.md)

Status: Planned
Complexity: Medium
Dependencies: None

## Objective and non-goals

Define the shared text/font and headless document boundary in authoritative Nitro sources. Do not implement native behavior, construct hidden views, or introduce compatibility aliases.

## Read before editing

Use these as a lookup map; read only the next decision's bounded context.

- `src/InkSignView.nitro.ts`: TextAnnotationOptions, TextModeOptions, AnalyzedPage, TextHandle, AddPagesOptions, InkSignViewMethods.
- `src/index.ts`: exported native/public types and validated page/text wrappers.
- `nitro.json`: autolinking constructors; `package.json`: Nitrogen 0.37.1 and validation scripts.
- Maintainer `references/architecture.md`: document operations, coordinates, scope; `references/development.md`: generated-source policy.
- Native-module development skill: implementation stage and version-matched Hybrid Object inheritance/type mapping guidance.

## Current behavior to preserve

Analyzed pages use synchronous text methods after asynchronous preparation. Viewer pages additionally support focus. Value removal reveals source text. Async commands are FIFO; native exceptions and public argument errors use existing error-prefix conventions.

## Implementation steps

1. Add `src/InkSignDocument.nitro.ts`. Define a non-Hybrid `PageTextMethods` interface shared by `AnalyzedPage` and the new `DocumentPage`; preserve every current text method except focus in that common interface. `DocumentPage.info: PageInfo` is a synchronous readonly property, computed for its stable page ID.
2. Define `NamedFontSource { name: string; uri: string }`. Add `font?: string | null` to TextAnnotationOptions and TextModeOptions. Add optional TextAnnotationOptions to `setTextValue(id, text, options?)` and `TextHandle.setValue(text, options?)`.
3. Define `DocumentOpenOptions` containing imagePageSize, targetDpi, jpegQuality, and androidFallbackFont with existing types/defaults. Define `DocumentAddPagesOptions` containing required sources and the same image conversion options; omit picker type and active-page selection.
4. Define `DocumentAddPagesResult { addedPageCount: number; pageCount: number }`. Define `InkSignDocument` with readonly pageCount; getPage(index): Promise<DocumentPage>; loadFonts(fonts): Promise<void>; addPages(options): Promise<DocumentAddPagesResult>; removePage(index), movePage(fromIndex, toIndex), rotatePage(index, degrees): Promise<void>; finalize(): Promise<string>; close(): Promise<void>.
5. Define a stateless `InkSignDocumentFactory.openDoc(uri, options?): Promise<InkSignDocument>`. Autolink only its platform constructors as `HybridInkSignDocumentFactory`; documents/pages are returned from owning native objects. Do not make a document constructible from JS without successful open.
6. Add viewer `loadFonts(fonts): Promise<void>`. Keep existing viewer method signatures otherwise unchanged. Use method comments to specify omitted-font retention, null reset, atomic options/value mutation, headless terminal/idempotent close, source immutability, and output transfer.
7. Use stable error prefixes `invalid_font`, `font_load_failed`, `font_name_conflict`, and `font_not_loaded`. Missing glyphs permit rendering fallback. Retain existing document/page/cancellation errors. Do not promise a new structured error.code field.
8. Run Nitrogen from the specs. Do not edit generated bindings manually. Defer runtime facade implementation/exports to task 10.

## Ownership and interface rules

All new Hybrid Objects use Swift on iOS and Kotlin on Android. No PDF/font bytes cross into JavaScript. Metadata is copied; native page/document handles own or borrow resources as specified in subsequent tasks. Font names are exact, case-sensitive strings; reject empty/whitespace-only names without silently trimming identifiers.

## Tests and expected results

Add compile-time API examples covering the headless sample, third-argument options, null font reset, and existing two-argument setters. Ensure headless types lack focus, pickers, state, and undo/redo. Native runtime tests belong to the owning platform tasks.

## Validation and completion

Run `npm run nitrogen` and `npx tsc --noEmit --pretty false`. Record signature-related facade failures until task 10 and native missing integrations until task 08/09; do not add placeholder methods to hide them. Complete when generated contracts match the source specs and every boundary above is represented. Public exports/tests must ultimately pass in task 10.

Proposed commit: `feat: define headless document and named font contracts`
