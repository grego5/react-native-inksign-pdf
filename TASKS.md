# Display-only PDF text compatibility overlay

Plan a native compatibility layer for source-PDF text whose font program is
unavailable to the platform renderer. The layer decodes text through the
platform PDF APIs, draws only non-universal Unicode glyphs with the platform
default font, and leaves universal ASCII glyphs transparent so existing
numbers and punctuation remain visible without duplication.

The overlay is presentation-only. It must not enter page history, dirty state,
undo/redo, JavaScript callbacks, or `finalize()` output. The source PDF remains
read-only and unchanged.

## Constraints

- Preserve the existing native-only PDF and geometry boundaries; add no public
  Nitro API and do not edit generated Nitrogen output.
- Extract PDF text off the UI/main thread and publish only immutable,
  generation-bound presentation data.
- Use canonical media-box-relative page coordinates with a top-left origin at
  platform presentation boundaries.
- Draw compatibility text below committed ink and user-created text.
- Do not attempt font-embedding detection in this first version. Contiguous
  drawable non-ASCII text is reconstructed as shaped compatibility runs;
  already visible ASCII remains source-PDF content and is not overpainted.
- Unsupported or malformed extracted runs are omitted without making an
  otherwise readable PDF fail to open.
- Page-turn previews must match the live page presentation.
- Export continues to consume the original source PDF plus committed user
  content only.

## Tasks

1. [Establish the overlay contract and deterministic fixture](Tasks/01-establish-overlay-contract-and-fixture.md)
2. [Render compatibility text in Android tiles and previews](Tasks/02-android-compatibility-overlay.md)
3. [Render compatibility text in the iOS page overlay and previews](Tasks/03-ios-compatibility-overlay.md)
4. [Lock export isolation, documentation, and device acceptance](Tasks/04-integration-validation-and-documentation.md)
   - [02a — Extract grouped compatibility spans and usable geometry](Tasks/02a-android-grouped-compatibility-extraction.md)
   - [02b — Render and validate shaped compatibility spans](Tasks/02b-android-shaped-compatibility-rendering.md)
