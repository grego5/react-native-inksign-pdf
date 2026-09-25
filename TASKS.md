# iOS text placement and editing

Implement the iOS equivalent of the Android text-interaction plan within the existing PDFView and page-overlay architecture. `InkSignPdfTextInteractionOverlay` owns transient editor, selection, and drag state; `InkSignView` owns PDFView viewport movement. Keep committed text in canonical top-left page coordinates and UIKit/PDFKit work on the main thread. Android is unchanged.

Use the existing `setTextDirection('ltr' | 'rtl' | 'auto')` method. Explicit direction is authoritative; automatic direction follows the active keyboard language when UIKit reports one, only while a new editor is empty. Preserve zoom when editing begins. Do not add a second public control or parallel document model.

## Tasks

1. [01 — Empty-text direction and lock](Tasks/01-empty-text-direction.md)
2. [02 — Text box and caret placement](Tasks/02-text-box-placement.md)
3. [03 — Selection and selected-text dragging](Tasks/03-selection-dragging.md)
4. [04 — Edit viewport and caret margin](Tasks/04-edit-viewport.md)

Complete in order. Automated tests should cover stable state and history contracts; use representative simulator/device interaction for direction, visual alignment, gestures, and viewport quality. Revise documentation and tests that describe superseded behavior. Do not import Android-specific IME, touch-slop, or tile-viewport mechanisms.
