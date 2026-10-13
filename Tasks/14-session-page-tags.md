# 14 - Support session tags and targeted page lookup

[Plan](../TASKS.md)

Status: Planned
Complexity: Medium
Depends on: 09-13

## Objective and non-goals

Give iOS viewer, headless, and mode-session clients Android's session-tag contract.
Use the core's existing ordered page records and preparation path. Add no tag
registry in presentation, tag persistence, getPagesByTag, or getPageById API.

## Read before editing

- `src/InkSignDocument.nitro.ts`: open/import options and document page queries;
  `src/InkSignView.nitro.ts`: PageInfo, PageQuery, TaggedPageQuery, viewer/session
  methods; `src/index.ts` and `publicArguments.ts`: wrappers and validation.
- Android `DocumentCore.kt`: getPageIdsByTag, getPage(query), admission guards;
  `DocumentCoordinator.kt`: pageIdsByTag, pageIndexByTag, appendCandidate.
- Swift core/page records from Tasks 09-11; `ios/TextCommands.swift`:
  numericPageIndex, getPage/getSessionPage, getPageIdsByTag, pageTagsAndroidOnly;
  `InkSignView+Document.swift` and `InkSignView+MutablePages.swift`: tag rejection.
- `ios/MutableDocumentTransactions.swift` and `DocumentCandidateLoader.swift`:
  retained page rebinding; Android tag cases in HybridInkSignViewTextKeyTest and
  PageRotationInstrumentationTest; architecture reference's Page tags section.

## Current contract

Shared signatures already contain tags and numeric/tagged queries, but Swift
rejects them. Android keeps one optional immutable tag on each session page.
Its synchronous ID lookup now returns an empty array for an empty reusable viewer.

## Implementation

1. Add an optional immutable tag to the core page record. Assign the open/import
   call's tag to every newly loaded page, including all sources in an import
   array. Keep existing tags on carried pages. Preserve tag and page ID through
   reorder, rotation, backend reconstruction, and presentation rebinding.
2. Match nonempty strings exactly without trimming, case folding, normalization,
   or uniqueness checks. Use existing JS admission validation and establish the
   same native boundary for direct native callers. Empty string is invalid;
   do not invent a default tag for initialDocument pages.
3. Implement synchronous core getPageIdsByTag over current ordered metadata.
   Return [] for no matches or no loaded document in an active reusable viewer.
   Reject a closed/closing headless owner or disposed viewer. Do not prepare
   analysis, touch selection/history, or change dirty state.
4. Resolve tagged getPage inside the existing core FIFO operation. The optional
   index is a zero-based position among current matching pages and defaults to
   zero. Prepare only the selected page through the existing cache. No match or
   an out-of-range match ordinal rejects with page_not_found; invalid index
   values retain existing argument errors. Preserve numeric behavior and the
   viewer/session omitted-query active-page behavior.
5. Delegate viewer/headless adapters to these core operations. Mode-session
   wrappers retain cancellation and result-validity checks outside the core.
   Expose tag in imperative page getState only; leave event shapes unchanged.
6. Deletion removes tag membership; replacement drops old pages/tags. Ordinary
   viewer close leaves an empty reusable owner. Export writes no tag metadata;
   reopen assigns tags only through new explicit options.
7. Remove the now-obsolete iOS tag rejection paths and Android-only documentation
   for this feature. Preserve public signatures; regenerate Nitro only if its
   authoritative spec/platform metadata changes, never by hand.

## Ownership and regression expectations

Tag/order reads run on the core owner executor; async selection uses its FIFO.
The backend and PDFKit neither own nor serialize tags. Reuse existing page and
mode lifetimes rather than adding another generation or lookup store.

Extend focused iOS cases for multipage opens, repeated-tag multi-source imports,
ordered IDs after move/delete/rotate/reconstruction, default-first and indexed
queries, current-order resolution of a queued query, empty-viewer reads, and
closed-owner rejection. Export/reopen must lose tags unless explicitly reassigned.
ID reads must cause no analysis, selection, dirty, or history changes.

## Validation and completion

- Static trace each adapter to one core lookup and one ordered page store.
- Run `git diff --check`; no builds or test execution without explicit approval.
  If approval arrives, use documented Mac source hashes and narrow tag/headless/
  mode tests plus applicable public-wrapper coverage. Report unavailable hosts.
- Complete when all three client forms share the contract and generated/public
  docs contain no stale iOS tag rejection. Mark runtime acceptance separately.
- Proposed commit: `feat(ios): support session page tags and targeted lookup`.
