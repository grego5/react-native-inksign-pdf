# 01 — Empty-text direction and lock

[Task index](../TASKS.md) · Status: Implemented; runtime validation pending · Complexity: Medium

## Objective

For a new iOS text box in `auto`, follow the active keyboard language while the editor is empty. Lock its base direction when content is entered; unlock and resample after all content is erased. Explicit `ltr`/`rtl` is authoritative. Commit the final direction with the annotation.

## Non-goals

No public API change, character-based inference, direction changes to previously committed annotations, or guarantee that every keyboard reports a language. Android is unchanged.

## Read before editing

- `ios/TextInteraction.swift`: `setTextDirection`, `placeTextAt`, `showEditor`, `adoptActiveInputDirectionIfAutomatic`, text-view callbacks, `finishEditing`.
- `ios/TextRendering.swift`: `InkSignPdfTextStyle.apply`; `ios/TextState.swift`: stored `isRTL`; `src/InkSignView.nitro.ts`: `setTextDirection`.
- `README.md`: direction contract; `.agents/skills/inksign-pdf-docs/references/swift-ios/viewport-input.md`: editor ownership.

## Baseline before implementation

New boxes start from explicit direction or device locale. `showEditor` checks `textView.textInputMode?.primaryLanguage` once after focus, then retains that direction. Reopened annotations use saved direction. UIKit's `primaryLanguage` is optional; absence cannot establish a new direction.

## Implementation

1. Keep requested direction policy separate from the new editor's effective direction and empty/nonempty lock state in `EditingState`. Preserve saved direction when reopening an existing annotation.
2. While a new `auto` editor is empty, sample `editor.textInputMode?.primaryLanguage` at focus and on UIKit's current-input-mode notification, or an equivalent main-thread editor callback. Observe only during that editor's lifetime. If unavailable, retain the current direction.
3. On the first empty-to-nonempty transition, sample once before final layout and lock. Ignore keyboard changes while nonempty, including mixed scripts. On nonempty-to-empty, unlock and resample. Explicit policy never samples. Apply a direction change through `InkSignPdfTextStyle.apply` and the existing anchor/layout path.
4. Save the effective `isRTL` through `settledAnnotation`. Update README and the iOS viewport/input reference with the best-effort and lock behavior.

## Tests and acceptance

- Use a deterministic state-contract test only if input-language changes can be supplied without simulating UIKit internals: empty `auto` can change, nonempty remains fixed, erase-to-empty permits change, explicit direction overrides language, and reopened committed text retains `isRTL`.
- On simulator/device with LTR and RTL keyboards, switch before typing, while text exists, and after erasing. Inspect caret side and saved/reopened direction. Record unavailable keyboard scenarios as unverified.
- Run `tools\test-ios-lifecycle.ps1` and focused iOS text XCTest on macOS. Report unavailable Xcode validation.

## Completion

Direction follows the empty/nonempty rule without changing the public API or committed content on keyboard change alone. Proposed commit: `fix(ios): track automatic text direction until content begins`.
