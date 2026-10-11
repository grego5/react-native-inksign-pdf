# 10 — Expose validated headless and shared font APIs

[Plan index](../TASKS.md)

Status: Planned
Complexity: Medium
Dependencies: 04, 05, 06, 07, 08, 09

## Objective and non-goals

Export usable JavaScript headless wrappers and shared viewer font/options calls with the repository's validation and async ordering conventions. Do not move document/native state into JavaScript or add new UI.

## Read before editing

- `src/index.ts`: type exports, createValidatedAnalyzedPage/createValidatedTextHandle, create handle methods and callAsync.
- Task 01 specs; `src/publicArguments.ts`: text/index/import validation and argumentError.
- `src/viewConnection.ts`: pending-call buffering, close/unmount cancellation; `src/index.ts`: createValidatedHandle and mode-session/page wrappers.
- `tools/public-arguments.test.cjs`, `tools/view-ref.test.cjs`, `tools/view-connection.test.cjs`, package test scripts.
- Maintainer public boundary/operation references; TypeScript, React/native-module implementation skills where applicable.

## Current behavior to preserve

Public wrappers validate input before native dispatch. Async view methods buffer until attachment; synchronous page/text methods require the native handle. Errors use prefixes in Error messages. Strict Mode/Suspense connection behavior must remain unchanged.

## Implementation steps

1. Lazily obtain the stateless InkSignDocumentFactory through NitroModules; export `openDoc` and all public document/page/font types. Validate source/options, await native open, and wrap the returned document independently of React/view connection.
2. Add shared validators for NamedFontSource arrays, required headless indexes, DocumentOpenOptions, and DocumentAddPagesOptions. Reuse existing image/text/index rules without permitting a missing headless source list or implicit active page.
3. Share text-method wrapper logic between AnalyzedPage and DocumentPage. Forward optional value options after validation; preserve existing two-argument behavior and synchronous exceptions. Keep only viewer focus on the viewer wrapper.
4. Forward live readonly metadata, indexed document operations, loadFonts, finalize, close, and base Hybrid Object methods. Native code owns terminal state/queue/resources; do not introduce a second JS operation scheduler or shadow document state.
5. Extend viewer connection methods with async loadFonts in invocation order, including calls before native attachment. Forward font/null on TextAnnotationOptions, TextModeOptions, TextHandle and ModeSession page wrappers.
6. Validate font names as nonempty case-sensitive strings or null where options permit it. loadFonts descriptors require name and URI; lookup/source readability remains native. Use existing prefixed argument errors, not invented error.code properties.
7. Keep a font override and the full value-options object as one native call. Do not implement it as setTextOptions followed by setTextValue.

## Ownership and API rules

Wrappers retain only native handles and validation behavior. Do not copy font bytes or PDF data into JS. Document pages survive moves but reject deletion/closure natively. Readonly page info is fetched from native state rather than captured at wrapper creation. Existing base dispose behavior remains available, with native cleanup as a fallback to explicit close.

## Tests and expected results

Add facade tests with native test doubles: factory errors propagate; no view is created; options and named sources are forwarded once; headless indexes/sources are required; metadata remains live; close forwards to the native terminal lifecycle. Verify preattachment viewer loadFonts ordering/cancellation and preservation through connection replay. Verify atomic setters use one dispatch and retain old call signatures. Use meaningful contract assertions rather than exhaustive guard predicate tests.

## Validation and completion

Run `npm run nitrogen`, `npm run test:public-api`, `npx tsc --noEmit --pretty false`, and `npm run build`. Both platform targets should now build; report actual platform evidence. Complete when the original user sample and named-font example typecheck against exported package APIs and facade tests pass.

Proposed commit: `feat: expose validated headless and named font APIs`
