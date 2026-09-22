# Task 06e: Preserve the Android document during replacement open

Back to task index: [TASKS.md](../TASKS.md)

## Depends on

- [Task 05](05-integrate-android-mutable-pages.md)

## Objective

Align Android replacement `open()` with iOS: an unsuccessful replacement leaves the previous document, session, page histories, dirty state, viewport, and editing mode usable.

## Implementation

1. Change `MutableDocumentCoordinator.executeOpen` and `PdfSessionWorker` so opening and validating a new working PDF does not close the current session. Retain the old session and working artifact until the replacement is published and presentation reaches open readiness.
2. Keep the old coordinator page collection and `SurfaceView` presentation available while preparing the candidate. Publish the new session, document state, and presentation as one transaction; if installation or readiness fails, restore the prior session and presentation. Superseded opens and disposal cancel candidates without restoring stale work.
3. Retire the old working artifact and session only after successful publication. Never touch the caller-owned source or retain a failed candidate. Preserve generation checks so delayed tiles, input, or exports cannot cross documents.

## Completion

- Worker/coordinator and connected tests cover invalid path, corrupt PDF, failed session open, failed presentation readiness, overlapping opens, disposal, and successful replacement. After every failed replacement, verify the old pages, histories, viewport, dirty state, render, and export remain usable. Run focused Android JVM and connected tests and `git diff --check -- ':!nitrogen/generated/**'`.

Status: Planned
