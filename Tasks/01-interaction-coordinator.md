# 01 - Own interaction transitions

[Plan](../TASKS.md)

Status: Complete (static); runtime verification deferred
Complexity: High
Depends on: none

## Objective and non-goals

Introduce `ViewerInteractionCoordinator` as the single owner of mode-session
replacement and interaction-transition ordering. Preserve document operations,
public signatures, text layout, and stroke algorithms.

## Read before editing

Lookup map; read only the context needed for the next decision:

- `ios/HybridModeSession.swift`: `beginModeSession`, `applySessionMode`,
  `invalidateModeSession`, `requireModeSession`.
- `ios/InkSignView+Document.swift`: `setInteractionMode`,
  `finishInteractionForLifecycle`, `applyInteractionMode`, command cancellation.
- `ios/InkSignView.swift`: `interactionMode`, `currentModeSession`, `editMode`.
- `ios/TextInteraction.swift`: `interactionState`, `interactionMode`,
  `finishForLifecycle`, `emitInteractionModeChanged`.
- `ios/InkInput.swift`: `cancelActiveStroke`, live/ended transaction boundaries.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`: Document operations.
- `.agents/skills/inksign-pdf-docs/references/swift-ios/view-lifecycle.md`: Ownership.

## Preserved contract

Every explicit `setMode`, including the same mode, replaces its token. Internal
text transitions and ordinary navigation retain that token. A session token's
originating mode is not the current editor activity. Ordinary prepared pages
remain document-bound; session pages also require their mode token.

## Implementation

1. Add `ios/ViewerInteractionCoordinator.swift`, owned by `InkSignView`, using
   the repository's main-thread boundary. Give it narrow dependencies for finishing
   text, cancelling ink, applying input policy, and retiring session commands.
   Avoid callbacks that expose the entire mutable view as the coordinator's API.
2. Move the current token, its validity checks, and base view/ink policy into
   this owner. Keep text activity authoritative in the overlay. Derive public
   mode: active picker, then text overlay activity, then base view/ink policy.
3. Implement one transition entry point for explicit mode changes and one for
   lifecycle suspension/finish. Encode the existing draft commit/discard and
   stroke cancellation behavior at these entries. Remove nested calls that
   repeatedly finish the same interaction.
4. Install the replacement token and stable internal state before invoking
   cancellation/completion callbacks. Recheck identity after calls that can
   emit public callbacks; a reentrant newer transition wins.
5. Have `HybridModeSession` and the Nitro `setMode` entry delegate to this owner.
   Retain FIFO dispatch in `InkSignView`; expose a narrow operation to retire
   queued/running callers associated with a token. Running work keeps its slot.
6. Route internal text-mode notifications and double-tap ink entry through the
   coordinator. Remove writable `InkSignView.editMode` and token storage once
   callers migrate; derive any required read-only ink predicate from its owner.

## Boundaries and completion

- Coordinator holds weak host references where a callback cycle would otherwise
  retain the viewer; host owns the coordinator. Disposal ends requests before
  releasing adapters. All transition state is accessed on the main thread.
- Document generation, history, target IDs, editor text, and ink snapshots stay
  with their existing domain owners.
- Done when mode transitions have one ordering path, token ownership has one
  location, and text completion can return to view without invalidating its token.
- Static check: `git diff --check`; inspect every old state write and caller with
  `rg`. Remaining integration verification belongs to Task 05.
- Proposed commit: `refactor(ios): centralize viewer interaction transitions`.

