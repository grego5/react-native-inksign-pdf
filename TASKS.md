# iOS viewer interaction ownership

Consolidate interaction transitions and viewport mutation into explicit owners.
Keep PDFKit rendering, the public API, document/history ownership, and existing
observable behavior. Android and generated bindings are outside this plan.

## Execution

| Order | Task | Status |
| --- | --- | --- |
| 01 | [Own interaction transitions](Tasks/01-interaction-coordinator.md) | Complete (static) |
| 02 | [Own input routing and coordinate picking](Tasks/02-input-routing.md) | Complete (static) |
| 03 | [Own viewport and keyboard geometry](Tasks/03-viewport-ownership.md) | Complete (static) |
| 04 | [Consolidate page presentation](Tasks/04-page-presentation.md) | Complete (static) |
| 05 | [Integrate, document, and review](Tasks/05-integration-verification.md) | Complete (static) |

Tasks 01–05 are implemented and statically reviewed. Runtime verification is
pending under the user restriction. Existing checks now reference the new
owners; Task 05 records the deferred verification.

## Ownership decisions

- `InkSignPdfDocumentCoordinator`: document identity, pages, committed history,
  analysis, PDF work, and document-operation lifetime.
- `ViewerInteractionCoordinator`: mode sessions, base view/ink policy, picker,
  input availability, and ordering of interaction transitions.
- `ViewerViewportController`, private to the interaction coordinator: viewport
  requests, motion, keyboard scroll space, geometry adapters, and zoom reporting.
- Text overlay: draft, selection, text layout, and caret geometry. Ink input:
  live stroke transaction. Both report outcomes to their transition owner.
- `InkSignView`: Nitro entry points, existing FIFO command dispatch, and platform
  assembly. PDFKit integration helpers apply the coordinator's decisions.

Session authorization and visible activity have different lifetimes. Navigation
and internal text transitions retain the mode token. A picker temporarily owns
input. Public mode is derived from picker, text activity, then base view/ink policy.

## Constraints

- Main-thread interaction and UI mutation; retain the serial PDF worker and FIFO
  command contract. Cancellation never releases a running worker's slot early.
- Keep distinct document, mode-session, and presentation request identities.
- Settle each request once. Settle callbacks after installing consistent state;
  callbacks may synchronously reenter and supersede the transition.
- Preserve displayed top-left public coordinates and canonical document geometry.
- No public API changes, new framework, renderer migration, or generic event bus.
- Keep implementation and coverage work separate. Task 05 owns existing-suite
  migration and verification notes. Additional coverage is not requested.
- Tests and builds remain prohibited until the user explicitly authorizes them.
  Source inspection and `git diff --check` are allowed. Task 05 records runtime
  checks as deferred; an implementation plan is not permission to execute them.

