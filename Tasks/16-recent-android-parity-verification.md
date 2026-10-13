# 16 - Close recent Android contract and ownership gaps

[Plan](../TASKS.md)

Status: Planned
Complexity: Medium
Depends on: 14-15 and existing checkpoints 08/13

## Objective and non-goals

Finish parity checks for recent Android adjustments after the ongoing extraction.
Reuse Task 13's integration cases; add only missing observations and correct
residual paths at their owning core/viewer boundary. Do not restart the refactor,
duplicate existing suites, add public methods, or expand into unrelated PDFKit
interaction defects or speculative optimization.

## Read before editing

- Final Swift core/history/fonts/handles/viewer adapters from Tasks 09-15.
- Android `InkHistory.kt`: appendFresh, appendText, retained identity/history
  indexes, state; `DocumentCore.kt`: explicit-page commands, metadata reads,
  empty-owner tag lookup; `NamedFontRegistry.kt`: alias/cache and cleanup policy.
- `src/InkSignView.nitro.ts`, `InkSignDocument.nitro.ts`, `src/index.ts`,
  `publicArguments.ts`: current methods, options, wrappers, and event shapes.
- Task 13 regressions, Android tag/rotation/oversized-page cases, iOS lifecycle/
  interaction tests, tools/view-ref.test.cjs, and the example's current callers.
- Maintainer architecture state/text/tag/operation sections, Android lifecycle
  history/fonts sections, corresponding iOS references, and README method guide.

## Current contract

Tasks 09-13 already establish core ownership, fixed headless history policy,
untracked base edits, named fonts, and current state/event shapes. Recent Android
work additionally guarantees empty-viewer tag reads, shared prepared rotation
caches, snapshot-before-eviction, and mutation/state metadata without dirty-state
content scans. Verify those details without implementing a second ownership model.

## Implementation and acceptance

1. Audit core history after Task 10. Fresh committed ink and first insertion for
   a new input target must not search composed page content for identities or
   cleanliness. Use retained identity/history metadata for text update policy,
   including deleted targets and redo-only/grouped-clear history. Keep any indexes
   inside the existing history owner and retire them with it. Do not create an
   identity-less untracked text subsystem or viewer bookkeeping mirror.
2. Confirm page dirty equals canUndo, redo-only history is clean, and genuinely
   independent untracked edits neither dirty content nor discard unrelated redo.
   Document dirty includes structural edits. Reads of dirty/undo/redo use history
   metadata, not source PDF scans, content equality, or checkpoint snapshots.
   Content flags may inspect committed in-memory content and exclude drafts and
   imported/reopened PDF content. Keep resetDirty/revision counters absent.
3. Verify named font lifetime with the existing registry/export resource owners:
   exact names, source reuse across aliases/repeated insertions, atomic load batches,
   omitted selection versus null reset, and no rejection merely for missing glyphs.
   Local/bundled iOS file URIs use the same named option in headless and viewer
   operations. Viewer-owned loaded fonts survive document replacement; terminal
   close/disposal releases owned resources after their users finish. Caller files
   remain unchanged. Apply the maintained format/embedding policy; platform-specific
   system fallback resource restrictions are not API inconsistencies.
4. Trace viewer undo/redo/clear/clearInk through local draft/active-page resolution
   into explicit core page commands. Empty-viewer commands retain established
   no-document behavior. Verify import selection current/firstAdded/lastAdded is
   viewer-only; headless operations require neither selection nor presentation.
5. Verify the final names on page/view/session/headless wrappers and the example:
   resolveInputUnderline, createInputArea, getInputTarget(s), focusInputTarget
   (viewer pages only), and requestUserTap (viewer/session only). Preserve existing
   text value/options/size methods and state/event payloads. Remove old aliases and
   obsolete iOS unsupported errors only for implemented shared features.
6. Extend existing focused cases with untracked edits around undo/redo/clear,
   deleted-target reinsertion, font source reuse and cleanup, empty-tag lookup and
   terminal-owner rejection, and Task 15's prepared geometry/lifetime observations.
   Reuse stable FIFO/worker barriers; do not restore submission-count or sleep gates.
   Validate fresh mutation/dirty paths by code trace rather than microbenchmarks or
   tests that simply mirror private implementation predicates.
7. Rewrite shared/iOS references to current ownership and shared feature support.
   Remove stale Android-only tags/headless/named-font claims once implemented;
   preserve Android-specific URI/backend restrictions. Keep the README concise
   with explicit receivers and common workflows. Record stable contracts, not
   implementation history. Confirm EOF/source diff checks are clean.

## Validation and completion

- No test/build commands are authorized by this task. Static code/contract traces,
  existing fixture edits, generated-signature inspection, and `git diff --check`
  are allowed. Run Nitrogen only for authoritative spec changes, not by hand.
- If runtime behavior is ambiguous, report the exact pending case and stop its
  dependent acceptance. Do not mask crashes or incompatible tests with guards.
- Once explicitly authorized, use the documented hash-verified Mac workflow for
  narrow headless/tag/rotation/history/font/lifecycle/export cases and applicable
  public API/example TypeScript checks. Run Android parity cases only for changed
  shared code/specs. Report actual executed counts and unavailable environments.
- Complete when one core owns committed data/history/targets/resources, optional
  presentation submits explicit edits and consumes changes, and appended contracts
  match Android. Keep implementation/static/runtime acceptance distinct; final
  acceptance includes Tasks 08, 13, and these additional parity observations.
- Proposed commit: `test(ios): close recent Android contract parity gaps`.
