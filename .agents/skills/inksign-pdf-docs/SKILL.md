---
name: inksign-pdf-docs
description: Maintain the React Native InkSign PDF repository using its current project policy, source-of-truth map, validation workflow, and subsystem documentation. Use for implementation, review, debugging, documentation, or validation in this repository.
metadata:
  short-description: Maintain React Native InkSign PDF with current project guidance
---

# React Native InkSign PDF maintainer guidance

Read the reference matching the task:

## Repository

- Workflow, policy, source map, architecture invariants, and validation:
  [development.md](references/development.md)
- Public API, ownership, lifecycle, coordinates, threading, export, and v1
  scope: [architecture.md](references/architecture.md)

## Android

- View ownership, document replacement, reset, and disposal:
  [android/view-lifecycle.md](references/android/view-lifecycle.md)
- Viewport transforms, tile navigation, touch input, and scale conversion:
  [android/viewport-input.md](references/android/viewport-input.md)
- Completed rendering, prediction, front-buffer state, and handoff:
  [android/rendering-front-buffer.md](references/android/rendering-front-buffer.md)
- Vector-preserving PDF export:
  [android/export.md](references/android/export.md)
- Diagnostics, debug replay, tests, and Android validation:
  [android/diagnostics-validation.md](references/android/diagnostics-validation.md)

## C++ stroke engine

- Input validation, contact lifecycle, centerline modeling, and replacement:
  [stroke-engine/input-modeling.md](references/stroke-engine/input-modeling.md)
- Signature brush ownership, width response, caps, dots, and terminal taper:
  [stroke-engine/styling.md](references/stroke-engine/styling.md)
- Cubic contours, geometry, and frame suffixes:
  [stroke-engine/geometry.md](references/stroke-engine/geometry.md)
- Circular signature brush adaptation scope and source provenance:
  [stroke-engine/circular-tip-provenance.md](references/stroke-engine/circular-tip-provenance.md)
- Prediction, committed/final frames, and platform consumption:
  [stroke-engine/prediction-frames.md](references/stroke-engine/prediction-frames.md)
- Replay, native/platform tests, and engine invariants:
  [stroke-engine/replay-validation.md](references/stroke-engine/replay-validation.md)

## Swift / iOS

- View ownership and document lifecycle:
  [swift-ios/view-lifecycle.md](references/swift-ios/view-lifecycle.md)
- Viewport, mode transitions, and touch conversion:
  [swift-ios/viewport-input.md](references/swift-ios/viewport-input.md)
- Live rendering and UIKit prediction:
  [swift-ios/rendering.md](references/swift-ios/rendering.md)
- Completed strokes, undo/redo, and callbacks:
  [swift-ios/history.md](references/swift-ios/history.md)
- Vector-preserving PDF export:
  [swift-ios/export.md](references/swift-ios/export.md)
- Stroke configuration and iOS validation:
  [swift-ios/configuration-validation.md](references/swift-ios/configuration-validation.md)

Keep the references and this skill aligned with the code in the same change.
When behavior, ownership, invariants, validation status, scope, canonical
sources, or documentation routing changes:

- Update the affected references to describe the implemented state.
- Update this file when reference topics or routing change.

## Documentation style

Maintainer references are current-state contracts, not project diaries.

- Add a statement only when it records a stable, externally relevant contract:
  ownership, data flow, invariants, interfaces, failure rules, or required
  validation. Place it in the reference for the subsystem that owns the fact.
- Rewrite an existing statement in place when behavior changes. Do not append a
  changelog entry or describe the old and new designs together.
- Remove content that is historical, speculative, duplicated elsewhere, or only
  explains an implementation transition. Keep a state transition only when it
  is observable behavior or a required lifecycle/failure rule.
- Prefer positive descriptions of the implemented system. Use a negative
  statement only when the absence itself is an externally meaningful invariant
  such as an API guarantee, ownership boundary, or safety rule.
- Cross-reference another reference instead of duplicating formulas, contracts,
  or detailed ownership rules. Keep sections short and bullets compact; use a
  diagram only when it communicates relationships more clearly than prose.
- Before finishing, compare every changed statement with the current
  implementation and focused tests. Delete claims that cannot be verified from
  code, tests, or an explicitly maintained contract.
