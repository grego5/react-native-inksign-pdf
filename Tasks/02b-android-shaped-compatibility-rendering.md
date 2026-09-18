# 02b — Render and validate shaped Android compatibility spans

[Back to plan index](../TASKS.md)

Status: Planned

Depends on: [Task 02a](02a-android-grouped-compatibility-extraction.md)

## Objective

Render each grouped compatibility span once with Android's system font and
bidi shaping so the supplied form approaches Acrobat's readable fallback.

## Implementation brief

- Prepare immutable drawing objects once during PDF open from Task 02a's text
  and rectangles. Tile and preview rendering must only apply the existing tile
  transform and draw these prepared objects.
- Use Android's default sans-serif fallback and platform bidi shaping for the
  complete span. Never reverse Hebrew manually or create one layout per glyph.
- Derive text size and baseline from font metrics fitted to the selected
  rectangle. Use the rectangle's top-left coordinates directly. Apply only a
  bounded horizontal fit when needed; reject unusable geometry instead of
  crushing or exploding text.
- Paint only reconstructed compatibility spans, leaving existing Latin,
  numbers, borders, and punctuation from the source PDF untouched.
- Retain one bounded first-draw diagnostic with grouped-run count,
  representative rectangles, prepared size/baseline, and changed-pixel count.
  Remove scalar-layout diagnostics after the visual issue is resolved.
- Update the Android rendering maintainer reference to describe grouped
  selection, shaping, preparation, and generation ownership.

## Regression expectations

- Live tiles and page-turn previews use the same prepared runs and remain
  visually consistent across zoom levels.
- Compatibility drawing remains below ink and committed user text and never
  enters export or document history.

## Completion and verification

- On the supplied PDF and the same Android device, Hebrew words are readable,
  correctly directed, approximately aligned, and close in size to Acrobat.
- Repeated zooming and preview rendering do not shift, duplicate, or recreate
  prepared text runs.
- Run the narrow Android compile/check path that is available plus
  `git diff --check`; visual device acceptance replaces pixel testing.

## Proposed commit title

`fix(android): render shaped compatibility text spans`
