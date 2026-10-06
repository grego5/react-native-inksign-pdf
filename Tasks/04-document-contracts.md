# Document coordinate ownership
[Plan](../TASKS.md)

Status: Implemented; verification deferred to Task 05
Complexity: Low

## Objective and scope
Document the implemented model after Tasks 01–03. Keep README a quickstart; maintainer references describe current contracts rather than the refactor history.

## Read before editing
README.md; .agents/skills/inksign-pdf-docs/references/architecture.md; android/viewport-input.md, android/view-lifecycle.md, android/export.md; swift-ios/viewport-input.md, swift-ios/view-lifecycle.md, swift-ios/export.md beneath the same references directory.
Trace each changed claim to the owning implementation symbol.

## Preserved invariants
Public API uses displayed page coordinates. IDs and captured-page lifetime remain unchanged. No public option or binding change is introduced by this refactor.

## Implementation sequence
1. In architecture.md, state canonical target ownership, local text layout, and derived presentation geometry once.
2. In platform viewport references, describe displayed operations and the mapper boundary. Cross-reference ownership instead of duplicating transforms.
3. In export references, state local layout → canonical content → captured page rotation, with source/PDF coordinate conventions confined to adapters.
4. Remove obsolete stored-display synchronization descriptions and duplicate geometry formulas. Keep observable vertical-rule rejection and request lifecycle rules.
5. Change README only if its usage examples contradict implementation; retain short examples and user-facing coordinate semantics.
6. Compare every changed statement with code. Leave pending verification status in the final task rather than architecture prose.

## Completion
References are concise, current and consistent across platforms. No implementation-transition narrative or speculative performance claim remains in changed paragraphs.
Proposed commit: Document canonical target and displayed operation contracts
