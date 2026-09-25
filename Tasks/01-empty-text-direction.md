# 01 — Empty-text direction and lock

[Task index](../TASKS.md) · Status: Complete · Complexity: Medium

## Objective

On Android, `auto` follows the reported keyboard language while the active editor is empty. The direction becomes fixed when text is entered and becomes eligible for keyboard resampling when all text is erased. Keep explicit React LTR/RTL authoritative. Save the final direction with the text annotation.

## Non-goals

No new React prop, annotation method, character-based direction inference, iOS change, or guarantee that every IME reports its active language.

## Read before editing

- `android/src/main/java/com/margelo/nitro/inksignpdf/TextInteractionOverlay.kt`: `armPlacement`, `setTextDirection`, `placeTextAt`, `currentInputLanguageDirectionHint`, `showEditor`, `annotationAt`.
- `src/InkSignView.nitro.ts`: `setTextDirection`; `README.md`: text direction contract; `.agents/skills/inksign-pdf-docs/references/android/viewport-input.md`: text input ownership.
- `android/src/androidTest/kotlin/com/margelo/nitro/inksignpdf/TextPlacementInstrumentationTest.kt`: direction and editor tests.

## Current behavior and invariants

Android samples `InputMethodManager.currentInputMethodSubtype` when placement is armed and tapped. The editor retains one `directionRtl`; `afterTextChanged` reapplies it. The ref method already accepts `ltr`, `rtl`, and `auto`. Direction and annotation state belong to the UI thread. A saved annotation carries `directionRtl` and must not change merely because the keyboard changes later.

## Implementation

1. In `TextInteractionOverlay`, distinguish the requested policy (`ltr`/`rtl`/`auto`) from the active editor direction. For explicit policy, use its direction even while the editor is empty; for `auto`, sample the current keyboard subtype when the empty editor gains focus, when it receives an input/selection callback, and immediately before applying the first insertion.
2. In the editor text watcher, detect empty-to-nonempty and nonempty-to-empty transitions from actual editor content. On empty-to-nonempty, sample the subtype once before final layout and lock the selected direction; do not infer from the first character. While content remains nonempty, preserve the direction through keyboard changes and mixed-script input. On nonempty-to-empty, unlock and resample the subtype if available. If the subtype is absent, retain the current empty-editor direction rather than guessing from entered characters.
3. Apply a direction change through the existing editor direction/anchor path so the padded box and caret move to the correct side without moving saved page content. Ensure `annotationAt` stores the direction present when editing finishes. Do not mutate an existing committed annotation until its normal edit transaction commits.
4. Update the Android behavior statement in `README.md`, the Nitro method comment if needed, and the Android viewport/input reference. State that `auto` is best effort because an IME may expose no usable subtype or may use one subtype for several languages.

## Tests and acceptance

- Add focused editor tests for: `auto` subtype change before first character, stable direction with nonempty text including mixed scripts, erase-to-empty then opposite subtype, and explicit LTR/RTL overriding the subtype.
- Verify saved annotation direction and reopening its editor. A subtype change alone must not alter committed content or history.
- Run `tools\test-android.ps1 -Mode jvm -Test com.margelo.nitro.inksignpdf.TextInteractionContractTest` and `tools\test-android.ps1 -Mode connected -Test com.margelo.nitro.inksignpdf.TextPlacementInstrumentationTest` when a compatible device is available. Report device or host limitations without claiming those tests passed.

## Completion

Editor direction follows the stated empty/nonempty rule; public API remains unchanged; focused tests and docs reflect it. Proposed commit: `fix(android): track auto text direction until content begins`.
