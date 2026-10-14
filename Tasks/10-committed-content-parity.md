# 10 - Align committed text, fonts, and history

[Plan](../TASKS.md)

Status: Complete (implementation and applicable simulator checks)
Complexity: High
Depends on: 09

## Objective and non-goals

Give the core view-independent text construction/reflow and Android-compatible
base/history semantics. Preserve native drafts in the viewer. Do not fake
untracked edits by clearing history or patching dirty flags.

## Read before editing

- Android `DocumentTextCommands.kt`, `InkHistory.kt`, and `NamedFontRegistry.kt`.
- `ios/TextCommands.swift`: resolve/value/options/construction and Android-only
  errors; `TextState.swift`: whole-page snapshots/history actions.
- `ios/TextRendering.swift`, Task 06 font resources, `History.swift`, and
  `InkSignDocumentState.swift`: state and target ownership.
- Current `src/InkSignView.nitro.ts`: PageTextMethods, PageInfo, options.
- Maintainer architecture state/history/text-value contracts.

## Current contract

Core committed text uses explicit targets and owner-local defaults. Viewer
wrappers apply draft precedence. History uses a permanent base plus keyed tracked
overrides, preserving independent base edits through undo/redo.

## Implementation

1. Move resolve/value/options/size/entry/construction/reflow into core text commands.
   Pass explicit values/options and keep core defaults/app direction independent
   of an overlay. Keep complete-line, hard-bound, matching, detection, and target
   identity contracts from the backend phase.
2. Core values use committed module text, then embedded source, then empty.
   Viewer wrappers apply active-draft precedence locally before entering the core;
   core operations never ask selection/editor state for a value or layout size.
3. Replace full-page undo restoration with permanent base plus identity-scoped
   tracked overrides/actions, including deletion tombstones. Swift may retain
   PKDrawing as its drawing value; an ink action changes drawing state, a text
   action changes its target, and clear is one grouped action. Unrelated base text
   survives undo/redo of ink or another target. Effective content composes base and
   overrides for both rendering and export.
4. Default viewer programmatic edits are tracked. Per-call `untracked: true`
   changes base content without adding undo or dirty state. Ignore the flag when
   that identity has retained tracked state in either undo or redo, including a
   grouped clear. Preserve redo for genuinely independent base edits; tracked
   edits clear redo normally. Do not save untracked as target formatting.
5. Headless cores have recording disabled: edits change base with no undo history.
   Page dirty equals nonempty applied undo stack; redo-only history is clean.
   Document dirty additionally includes structural changes. Export leaves these
   states unchanged. Internal cache revisions may remain; add no public counter
   or resetDirty API.
6. Add owner-local named-font loading with Android's atomic batch/name-conflict
   contract. Perform local file/font parsing asynchronously, then resolve loaded
   names synchronously. Omission retains selection, null selects the system font,
   and unknown names report `font_not_loaded`. Use owned CGFont/CTFont resources
   without process-global font registration. Reuse the same exact font resources
   in layout and Task 06 export. Android resource URI forms stay Android-specific.
7. Viewer text/ink commit submits the same core mutation used by page operations.
   Compare captured before-content/identity to current committed content before
   publishing; stale drafts/strokes cannot overwrite newer core edits.

## Static validation and completion

- History now composes permanent base and identity-scoped text/drawing overrides.
  Retained undo/redo identities force tracked writes; independent base writes
  preserve redo and survive unrelated history application.
- Core candidate creation applies construction-selected history recording.
- Core text resolution/value/options operations use stable page contexts and
  committed state. Viewer draft forwarding and core-bound handles are integrated.
- Named fonts load atomically, reuse source resources across aliases, and supply
  the same face to measurement, rendering, and export. Current/retained text
  identity metadata belongs to history; fresh drawing/text edits avoid composed
  page scans.
- Whitespace checks pass. Public wrapper checks passed 22/22 through the authorized
  validation chat; current Swift compilation and focused core/history/font checks passed.

- An untracked target survives unrelated undo/redo and does not dirty its page;
  a tracked target cannot escape retained history through the flag.
- No core text path reads an overlay, live selection, or active viewer page.
- Fonts, effective content, history, and export each have one owner/source.
- Run `git diff --check`. Proposed commit:
  `feat(ios): align core text fonts and base-history semantics`.
