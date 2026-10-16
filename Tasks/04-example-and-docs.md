# 04 — Example and current-state documentation

[Plan index](../TASKS.md)

Status: Complete — native document methods replace Expo selection; docs updated
Complexity: Medium
Depends on: 02, 03

## Objective / non-goals

Demonstrate native open/import selection and remove Expo picker glue. Keep the
example's signing, text, zoom, and selection controls unchanged. Update current
contracts only after native behavior exists.

## Read before editing

- `example/src/App.tsx`: document state, `addPages` helper, Open file/Add pages actions.
- `example/package.json`, `example/package-lock.json`, `example/app.config.ts`:
  Expo dependency/plugin declarations.
- `README.md`: startup, Document methods, examples.
- Maintainer references: `architecture.md` (import/export, command lifetime),
  `android/view-lifecycle.md` (inputs), `swift-ios/view-lifecycle.md` (publication/retirement).

## Existing behavior

The example uses `expo-document-picker`, maps its results to URIs, opens the first
source, appends the rest, then sets document state. Native headless calls already
own document lifetime. The README describes explicit sources only.

## Implementation

1. Create the owner once with `createDocument({ androidFallbackFont })` and mount
   the viewer immediately. Call `document.addPages()` for native selection.
   Show existing error UI for failures; user cancellation imports zero pages.
2. With a document, call `document.addPages(options)` directly; omitted sources
   prompts natively. Preserve the existing page selection and attached document.
   Keep React state only for the returned owner and existing UI controls.
3. Remove the Expo picker import, dependency, and any plugin declaration. Regenerate
   only the example lockfile as required by dependency removal; preserve unrelated
   package versions. No JS URI copies/cache files or picker-specific session state.
4. README: retain its method-list/example format. Show synchronous creation and import,
   `type` filtering, explicit-source bypass, and brief cancellation behavior.
   Keep ownership internals in maintainer references.
5. Rewrite explicit-sources-only statements in owning references. Record native
   presenter independence, FIFO selection phase, close cancellation, staged-file
   handoff/retirement, and existing import selection behavior. Cross-reference
   shared contracts instead of repeating platform formulas or transition stories.

## Ownership / lifecycle

The app chooses when to request input and retains/closes the document. Native owns
picker presentation, provider access, staging, mutation, and cleanup. Removing the
viewer while picking does not abandon the document command.

## Regression work / validation

Task 05 owns observable example/native checks and dependency validation. This task
uses static searches for Expo picker references and `git diff --check`; no tests or
builds. Report incomplete dependency resolution rather than hand-editing lock entries.

## Completion / proposed commit

Complete when example actions use only library document methods, Expo picker is
absent from example dependency/configuration sources, and docs match implemented
behavior without a second picker API.

Commit: `docs(example): use native document selection`
