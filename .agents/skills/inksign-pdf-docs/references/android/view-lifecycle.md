# Android document lifecycle

## Ownership

- Shared document, target, and session ownership:
  [architecture](../architecture.md#android-document-ownership).
  `SurfaceView` owns presentation/input; `TextInteractionOverlay` owns drafts
  and editor state. `PdfSessionWorker` serializes backend access and cleanup.
- `SurfaceView` owns `ViewerDocumentState`, which holds active-page selection
  while borrowing document reads from the core. Open selects the first page;
  reorder and rotation preserve selected identity. Removing that page selects
  the page at its former index, or the last surviving page. Import selection
  applies when the viewer installs published pages; headless mutations have no
  active-page state.
- Document inputs accept local files and Android content/resource URIs. The viewer
  picker supplies URIs to the shared loader; streams close after copying.
  Cancellation retires staged files and releases request ownership before reuse.
- `SurfaceView` owns/recycles the base-raster cache; navigation borrows previews.
  Document/structural publication and disposal release it; navigation/viewport
  changes reuse it. See [rendering](rendering-front-buffer.md#pdf-pages)
  and [handoff](viewport-input.md#ink-and-navigation).
- The worker's text-geometry LRU holds at most eight pages and 8 MiB estimated
  storage. Navigation retains entries; session replacement/closure releases them.
- The core retains one prepared context per stable page; Android page handles
  reference it weakly. Mode tokens govern viewer-handle validity independently
  of analysis lifetime. Mode cancellation retains analysis for later handles.
  Page deletion releases affected contexts, targets, and source glyphs;
  replacement/teardown releases all of them.

- Session page tags belong to core page records and survive structural publication.
  Assignment, lookup, and export lifetime follow the shared
  [page-tag contract](../architecture.md#page-tags-android).

## Fonts

- `loadFonts()` atomically publishes named local sources after validating static,
  single-face TrueType outlines. Names sharing a normalized source reuse bytes,
  a typeface, and a private font file. Synchronous edits use preloaded resources.
- Named fonts belong to the core and survive document replacement. Viewer close
  or terminal headless close retires them after backend users finish. Registry
  publication runs on the UI thread; loading and file retirement run on IO.
- `androidFallbackFont.uri` accepts HTTP(S), local file/path, content/resource URI,
  Expo `file:///android_res/` URI, or a bare resource name. Source and reconstructed
  font faces are capped at 64 MiB. Streams and HTTP connections close after
  resolution; cancellation prevents resource publication.
- `open()` and first-document `addPages()` capture fallback configuration. Document
  state retains resolved bytes for structural reopen; JNI copies them into
  worker-owned storage. Replacement/closure releases them after worker users finish.
- Font rendering, embedding, and missing-glyph behavior:
  [export](export.md#text-and-fonts).

## Opening

- Follow shared [ordering/cancellation](../architecture.md#document-operations).
- Each attempt owns an ID and coordinator-owned working file. PDF input copies
  directly into that file; image input is encoded as PDF before backend preparation.
  Abandoned working files retire after backend users finish.
- `prepareOpen()` clears the previous document and prepares a detached reader/model.
  Headless opening proceeds directly to commit. Viewer opening waits cancellably
  for usable viewport geometry and prepares presentation before committing.
- `commitOpen()` publishes matching reader/model state in a non-cancellable phase;
  viewer presentation installs synchronously before callbacks and tile requests.
  `finishOpen()` discards an unpublished candidate and ends the operation; clients
  must finish every prepared open.
- Failure before commit leaves the replacement viewer empty. Targeted cancellation
  detaches its waiter without invalidating unrelated tile/preview work;
  replacement/disposal invalidate the operation session.

## Page history and disposal

- The core owns histories keyed by stable page IDs; structural dirty state is
  separate from page-content history. Viewer clear/clearInk commands enter the
  core with explicit page IDs and remain page-local and undoable. Headless documents retain committed
  content without recording undo actions.
- Each history owns a permanent base and ordered tracked overrides. Composed
  snapshots suppress base entries overridden or deleted by a tracked identity,
  then append tracked content. Rendering, text lookup, and export use that composition.
- Stroke commits and first text insertions append directly without identity searches
  or composed-content snapshots.
  History indexes previously inserted text IDs until document retirement, so an
  empty target with retained edits uses the existing-identity mutation policy.
- Programmatic text `untracked: true` mutates the base without adding an undo
  action or discarding unrelated redo. If the identity occurs in current tracked
  content or retained undo/redo, the edit records normally. Untracked edits leave
  dirty state unchanged. See [state contracts](../architecture.md#state-inspection-and-events).
  Tracked clear/delete masks base content; undo restores it. New base entries
  survive older clears.
- Presentation installation and surface disposal release viewer resources only.
  Document replacement, viewer close, and terminal cleanup retire committed content
  and history through the core lifecycle.
- Rotation updates orientation/geometry revision while preserving source and
  content identity. Assembly retains orientation; [export](export.md) persists it.
- `clearInk()` cancels live ink; page state reads committed session content.
  See [state contracts](../architecture.md#state-inspection-and-events).
- Reopened assembly candidates validate page count, order, and source geometry.
  Image geometry uses reopened PDFium precision; existing pages retain orientation.
  Import selection follows shared
  [defaults](../architecture.md#system-boundaries).
- Viewer close clears the document while retaining a reusable core. Disposal
  cancels core work, unsubscribes the viewer, and releases presentation/input.
  Backend readers and owned files retire after their users finish. Headless close
  follows the [terminal close contract](../architecture.md#document-operations).
