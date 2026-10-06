# Canonical text storage and displayed operations

Store target identity and geometry in canonical page coordinates. Keep placement,
editing and focus in displayed coordinates, derived through one mapper. Preserve
text's local layout and wrapping through its layout-to-canonical transform.

## Constraints
- Public API and displayed-coordinate inputs remain unchanged.
- Coordinator owns targets/history; overlay owns live interaction.
- Rotation changes presentation and persisted page orientation, not target identity.
- Existing direction, field eligibility, value precedence and lifecycle contracts remain.
- Pager gestures, transition animation and preview-failure recovery are separate work.
- Tests and builds remain deferred. Regression source and execution belong to Task 05.
- Implement in order; each platform task includes its callers to keep that platform coherent.
  Cross-platform alignment is complete after Task 03. Record intermediate limitations.

## Tasks
1. [Android coordinate ownership](Tasks/01-android-coordinate-ownership.md)
2. [iOS coordinate ownership](Tasks/02-ios-coordinate-ownership.md)
3. [Export and rotation integration](Tasks/03-export-and-rotation-integration.md)
4. [Document contracts](Tasks/04-document-contracts.md)
5. [Verification](Tasks/05-verification.md)

Tasks 01–04 are implemented. Task 05 remains planned; tests, builds, and runtime
verification for this refactor remain pending.
