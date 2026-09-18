# 02a — Extract grouped Android compatibility spans and usable geometry

[Back to plan index](../TASKS.md)

Status: Planned

Depends on: [Task 02](02-android-compatibility-overlay.md)

## Objective

Replace scalar-by-scalar Android selection with immutable logical text spans
whose selection results provide usable rectangles for later shaped rendering.

## Implementation brief

- Keep extraction inside `PdfSession.open` on the serial PDF worker and keep
  all results private to the owning session generation.
- Decode the page text stream without reversing RTL text. Group adjacent
  drawable non-ASCII scalars into the smallest useful shaped span, retaining
  internal spaces or punctuation only when they occur between candidate
  characters. Do not create runs for already visible ASCII-only content.
- Call `selectContent()` once for each grouped span. Copy the selected text and
  usable returned rectangles into worker-owned values before closing the page.
  Do not derive font size or advance from integer boundary points.
- When selection splits a span across multiple rectangles, emit one logical
  run per rectangle using the corresponding text portion. Omit unresolved or
  malformed spans without failing PDF open.
- Remove the scalar boundary/line-matching path and its per-character omission
  accounting. Keep bounded debug totals for candidates, accepted grouped runs,
  and rejected geometry without logging document text.

## Regression expectations

- Source PDF rendering, previews, export, history, dirty state, callbacks, and
  public APIs remain unchanged.
- Extraction remains synchronous on the PDF worker and creates no per-frame or
  per-tile selection work.

## Completion and verification

- The supplied PDF produces grouped Hebrew words or phrases rather than
  hundreds of one-character runs.
- Representative accepted rectangles have meaningful width and height instead
  of `1x1` scalar geometry.
- Android compilation/static inspection and `git diff --check` pass; do not add
  pixel tests.

## Proposed commit title

`fix(android): group compatibility text extraction`
