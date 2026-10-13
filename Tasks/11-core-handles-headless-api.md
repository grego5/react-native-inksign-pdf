# 11 - Bind handles and expose the headless API

[Plan](../TASKS.md)

Status: Planned
Complexity: High
Depends on: 10

## Objective and non-goals

Make document/page/text handles address the core and expose the existing headless
API on iOS. Preserve public method/state shapes. No handle registry in React,
public attach-view API, or renamed inspection methods are introduced.

## Read before editing

- `src/InkSignDocument.nitro.ts`, `InkSignView.nitro.ts`, `index.ts`, and
  `nitro.json`: HybridObject platform declarations, factory, wrappers, contracts.
- Android `HybridInkSignDocument.kt`, `HybridAnalyzedPage.kt`,
  `HybridTextHandle.kt`, and `PreparedDocumentPage.kt`.
- `ios/HybridAnalyzedPage.swift`, `HybridTextHandle.swift`, `HybridModeSession.swift`:
  view references and authorization; core from Tasks 09-10.
- Maintainer architecture prepared-page, state, and operation contracts.

## Current contract

Headless Nitro types and openDoc dispatch are Android-only. Swift page handles
call the view for every data operation and reject some normal options. Viewer
mode tokens authorize session-bound work; ordinary handles are document-bound.

## Implementation

1. Add Swift platforms to InkSignDocumentFactory, InkSignDocument, and DocumentPage
   declarations and autolinking. Implement `HybridInkSignDocument` and its factory
   as thin core adapters: openDoc, getState/pageCount, explicit-index getPage,
   loadFonts, add/remove/move/rotate, finalize, and close. Preserve signatures.
2. Delegate headless async work to the core FIFO and synchronous page methods to
   the published core state. A document handle owns its core; page/text handles
   retain identity/analysis according to core lifetime and do not keep it alive
   after the document owner retires. Disposal of a page never closes the document.
3. Use document generation plus stable page ID for all page data operations.
   Navigation/reorder/rotation preserve identity and current getState position;
   deletion, replacement, terminal close, or owner disposal invalidate access.
   Bind text handles to the same core/page/text identity, independent of selection.
4. Implement AnalyzedPage data methods through the same core page adapter. Its
   weak viewer adapter is needed only for draft precedence, focus, and optional
   mode authorization. Mode checks remain in that wrapper before dispatch and
   before accepting async results; no mode field or weak view belongs to the core.
5. DocumentPage has data methods only. AnalyzedPage adds viewer focus. Selected
   TextHandle actions use the core mutation and local draft reconciliation; no
   extra preparation is required simply to operate on selected committed text.
6. Return current PageInfo through getState: identity, displayed geometry/rotation,
   current index/count, session InkSign hasInk/hasText, dirty, canUndo/canRedo.
   Imported PDF ink/text is excluded from content-presence flags. DocumentState
   contains only documentId/pageCount/isDirty. No getInfo, hasInk method,
   resetDirty, or public revision counter is restored.
7. Remove the iOS unsupported-platform gate from openDoc and Android-only option
   restrictions that Tasks 09-10 now implement. Keep androidFallbackFont explicitly
   Android-specific. Update JSDoc for shared named fonts/untracked semantics,
   preserving all argument shapes and JS boundary validation.
8. Run `npm run nitrogen` for source-spec/autolinking changes; never hand-edit
   generated files. Generation is not runtime verification or permission to run
   tests/builds. Migrate direct callers to the final signatures without aliases.

## Static validation and completion

- An ordinary headless page edit reaches the core without a view callback.
- A session wrapper can cancel authorization without closing the shared core.
- Terminal headless close rejects new access and successful caller-owned outputs
  remain usable after cleanup, matching Android.
- Inspect generated platform mappings and run `git diff --check`.
- Proposed commit: `feat(ios): expose core-bound headless document handles`.
