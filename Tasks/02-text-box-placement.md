# 02 — Text box placement and writing-rule snapping

[Task index](../TASKS.md) · Status: Implementation in progress · Complexity: High

## Objective

Place a new text box horizontally centered on its original tap. With no matching
writing rule, align the inner text area's bottom edge to the tap. When a nearby
horizontal rule spans the tap, align the padded box's outer bottom edge to the
rule. Preserve the chosen center and bottom anchor as text grows, subject to
page-edge clamping.

## Direction

- Explicit `ltr` and `rtl` remain authoritative.
- For `auto`, use the keyboard language when available and otherwise the device
  locale while the new editor is empty. Keyboard-language changes may update
  the empty editor.
- Text containing a strong RTL character uses RTL alignment. When the last such
  character is deleted, restore the editor's automatic base direction. Erasing
  all content allows the keyboard language to update that base again.
- Direction changes affect alignment inside the box; they do not move its
  horizontal center or selected vertical anchor. Save the effective direction
  with the committed annotation.

## Writing rules

- Opening reads page metadata without scanning for placement rules. Entering
  placement scans only the active page asynchronously for horizontal stroked
  paths and rows of small, evenly spaced filled rectangles.
- Keep the result in memory while that page remains active and reuse it when
  placement is entered again. Clear it when the page or document changes. A
  replaced, closed, or disposed document ignores late results. Apply this
  lifetime on both Android and iOS.
- A tap selects only a nearby candidate whose horizontal span contains the
  touch. Until candidates are ready, or when no candidate qualifies, use
  ordinary placement.
- Select the rule before measuring and showing the editor. If its box cannot
  fit above the rule, use ordinary placement. Keep the choice as temporary
  editor state; do not add detector metadata to annotations.

## Verification

- Cover the supplied four-rule and dotted-row PDFs, ordinary placement while a
  scan is pending, no match, stale generations, and page-edge clamping.
- Cover LTR, RTL, automatic direction, strong-RTL insertion and deletion, and
  keyboard-language changes while empty.
- Verify that the first displayed box is centered on the touch, uses the
  selected bottom anchor, and retains that anchor while text grows.
- Inspect representative placement on an iOS simulator or device at multiple
  zoom levels, alongside drawing and PDF navigation.

## Completion

Automated tests cover stable geometry and scanner contracts. Visual placement
and gesture quality are verified through representative runtime inspection.
