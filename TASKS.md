# Page selection and text flow on Android and iOS

Status: Planned

Implement the shared public options and Android behavior first, then add the equivalent iOS behavior in separate tasks. The Android tasks own the Nitro option changes and binding generation; the iOS tasks consume those generated options. Keep existing unrelated worktree changes intact. Do not implement these tasks while editing this plan.

1. [Choose the active page after `addPages()`](Tasks/01-add-pages-active-page.md)
2. [Limit and vertically anchor programmatic text](Tasks/02-text-lines-vertical-anchor.md)
3. [Choose the active page after `addPages()` on iOS](Tasks/03-ios-add-pages-active-page.md)
4. [Limit and vertically anchor programmatic text on iOS](Tasks/04-ios-text-lines-vertical-anchor.md)
5. [Apply text flow options to manual placement on iOS](Tasks/05-ios-manual-text-flow.md)

The user's existing instruction prohibits running tests or builds. Each task lists the intended validation for later execution; during that restriction, perform static review and `git diff --check` only, and report runtime verification as unrun.
