# Android text placement and editing

Implement the approved Android-first text interaction plan. iOS remains unchanged in this pass. `TextInteractionOverlay` owns editor and gesture state; `PageViewport` and `InkDocumentController` own viewport targets. Keep page geometry in top-left-origin canonical page units and UI state on the Android UI thread.

The existing React ref method `setTextDirection('ltr' | 'rtl' | 'auto')` is the app control. Do not add a second prop or annotation API. In `auto`, keyboard language is best effort; explicit LTR/RTL is authoritative. Keep the current zoom when text editing begins.

## Tasks

1. [01 — Empty-text direction and lock](Tasks/01-empty-text-direction.md)
2. [02 — Consistent text box and caret placement](Tasks/02-text-box-placement.md)
3. [03 — Selection and immediate dragging](Tasks/03-selection-dragging.md)
4. [04 — Edit viewport and caret margin](Tasks/04-edit-viewport.md)

Complete in order. Preserve unrelated committed fixes and revise existing tests or documentation when they encode the old behavior. Every task must pass its focused checks before the next begins; run the integrated checks in Task 04.
