# Architecture overview

React Native InkSign PDF is a Fabric/Nitro view for signing ordered local PDF
documents. JavaScript composes the screen and sends commands; native code owns
document bytes, page presentation, input conversion, committed content, history,
and export.

## System boundaries

- `src/InkSignView.nitro.ts` defines native interfaces; `src/index.ts` defines
  React session props. JS receives state/page events, prepared text metadata,
  and selection IDs, not PDF data or per-frame geometry.
- [`src/index.ts`](../../../../src/index.ts) validates public arguments before
  native dispatch. Platforms check document-dependent bounds when admitting a
  command; loaders validate PDF, image, and OS data at ingress.
- The stable React ref buffers async calls until native attachment, in invocation
  order. Immediate close/teardown reject undelivered work; synchronous calls
  require attachment. Strict Mode replay and Suspense hiding preserve the connection.
- `initialDocument` loads a local PDF/JPEG path or `file://` URI once per keyed
  session; errors use `onStateChange.error`. JPEG detection uses file bytes and
  the shared encoder creates one A4 page. Caller files remain unchanged.
- Public placement/focus use displayed top-left page points. Text bounds have
  physical edges independent of direction; dimensioned taps extend right/down.
  Dimensions are hard limits; `maxLines` caps complete lines without forcing a
  count. Preview/export share retained lines. Bounded editors admit fitting input,
  allow deletion, and retain text through reflow; programmatic values clip overflow.
- `addPages()` selects the current, first added, or last added page through
  `activePage`; the default keeps the current page, or selects the first page
  when creating a document. Empty and cancelled imports leave document state
  unchanged.
- Image imports use configurable DPI and JPEG quality, with defaults of 200 DPI
  and 0.72. Rasterization preserves page aspect ratio; explicit DPI is capped
  by source resolution. PDF inputs retain their original pages.
- Each view owns an independent coordinator: published document, stable ordered
  pages, active page, committed history, and operation session. The UI thread
  owns presentation/callbacks; backend publication uses validated detached candidates.
- Android renders PDFium tiles beneath native annotation presentation and uses
  the shared C++ stroke engine. iOS renders PDFKit pages through Quartz and
  uses PencilKit for ink input; export retains source pages and adds committed
  text and filled vector signatures as PDF annotations.

## Document model

- Page order and active-page identity are document state. Ink and text are
  committed per-page content; active gestures, predictions, editor drafts, and
  selection are temporary presentation state.
- Prepared page handles retain immutable source analysis and a stable page ID.
  The coordinator owns numeric text IDs, target metadata, and committed history;
  the overlay owns drafts/selection. IDs are monotonic per view. Async preparation
  enables synchronous resolution/value operations on the captured page.
- Field lookup compares complete joined labels first, then token frequencies
  when no joined match exists. Repeated words matter; fallback allows extracted
  word-order differences. Partial labels/substrings do not match.
- Value precedence: draft → committed module text → embedded text → empty.
  `setTextValue(id, '')` removes module text and reveals preserved source text.
  Re-resolution preserves formatting.
- Named detection/adoption uses rule width and one label-height band above a
  bottom-anchored rule, below a top-anchored rule; exclude only selected label
  glyphs. Free targets use placement bounds. Competing module annotations reject
  with `text_target_ambiguous`. Named focus uses the rule; free focus uses center.
  Vertical rules reject new field insertion/focus; existing text stays editable.
- Target bounds, rule endpoints, and detection regions use canonical rotation-zero,
  media-box-relative top-left coordinates. Named identity uses source glyph ranges
  and rule identity; free bounds are canonicalized before reuse/adoption.
- Annotations retain local layout/flow bounds and captured orientation.
  Layout → canonical → display mapping preserves wrapping. Rotation preserves
  target identity, canonical geometry, layout, and history.
- Named targets keep their source association and detection region when module
  text moves. Free targets track accepted placement, including undo and redo,
  and refresh their embedded fallback from retained immutable source geometry.
- Opens and page mutations prepare detached candidates. Failed or cancelled
  page mutations leave the current document intact. Caller source files are
  never overwritten.
- Finalize exports an immutable snapshot of committed content from the current
  working document to a separate output. It does not consume or replace the
  working document.

## Document operations

- The coordinator owns document-session identity, pending document operations, and
  cancellation for its view. Each operation captures its session and request
  identity when admitted.
- Native asynchronous document, preparation, and viewport commands execute FIFO.
  Their document and implicit active page bind when execution begins. Earlier mutations finish before ordinary
  open/close. Presentation requests for a retiring document are cancelled when
  replacement/close is scheduled. Other synchronous commands and user gestures act immediately.
- `setMode()` requires ready presentation and replaces the mode-session token,
  including same-mode requests. Session methods/pages cancel on supersession,
  scheduled replacement/close, or disposal; ordinary pages are document-bound.
  Navigation/reordering and internal text transitions retain the token. Handles
  retain tokens/weak view references; handle disposal does not end the session.
- `requestPageCoords()` owns exclusive `pageCoords` input and captures document,
  active page, and geometry revision. Tap waiting releases the command queue.
  Page/geometry/mode changes or teardown cancel it. Direct calls replace the
  session and finish in view mode; session calls restore their originating mode
  after selection/navigation cancellation. Pan/pinch are not selection taps.
- `close()` waits its turn; `close(true)` cancels queued/running callers, invalidates
  late publication, and clears the viewer. Disposal always cancels immediately.
- Opening waits for loading and usable presentation geometry, then resolves after
  installation. Failed opening leaves the viewer empty. Prepared handles remain
  bound to their original document/page and reject after invalidation.
- `onStateChange` emits complete, deduplicated viewer snapshots including an opaque
  document ID and nullable load-error message. Starting a load clears the error.
  Modes are `view`, `ink`, `textAdd`, `textEdit`, and `pageCoords`; selection IDs are reported
  separately by `onTextSelectionChange`. Successful opening creates identity;
  page mutations retain it.
  Empty state uses null identity, view mode, and false dirty/undo/redo flags.
- `finalize()` returns a temporary `file://` URI; artifact ownership uses paths.
- Check operation identity on the owning thread before publishing mutations,
  emitting asynchronous callbacks, and settling promises. Superseded successes
  and failures reject with `operation_cancelled`; each promise settles once.
  A result already settled before replacement cannot be withdrawn.
- Cancellation prevents publication, without reverting committed edits or releasing
  a running worker's queue slot/resources prematurely. Retire unpublished outputs;
  published exports remain view-owned until disposal. See platform export references.
- Disposal invalidates the session, cancels pending operations, clears callbacks
  and presentation, and releases resources through the same cleanup rules.
- Font-file ownership: [Android lifecycle](android/view-lifecycle.md#ownership).
  iOS uses system font fallback.
- Required validation covers replacement during each asynchronous operation,
  stale success and failure, empty imports, repeated opens, disposal, exactly-once
  settlement, unchanged newer content/history, and eventual resource cleanup.

## Scope

The v1 surface supports ordered PDFs, PDF and image page insertion, page-local
ink and text, undo/redo, and signed-PDF export. iOS preserves visible source
page content, order, supported boxes, and rotation, and exports module text and
ink as locked annotations with vector appearances. Advanced source PDF
semantics such as forms, links, outlines, tagged structure, layers, scripts,
embedded files, and existing digital signatures are outside the editing
contract; their loss does not block the workflow. Non-mobile platforms and
unrelated PDF extensions are outside this scope.

## Subsystem references

| Area | Reference | Responsibility |
| --- | --- | --- |
| Public API | `src/InkSignView.nitro.ts` | Props, commands, and callbacks. |
| Repository workflow | `development.md` | Source map, project policy, and validation entry points. |
| Android lifecycle and export | `android/view-lifecycle.md`, `android/export.md` | Document publication and output ownership. |
| iOS lifecycle and input | `swift-ios/view-lifecycle.md`, `swift-ios/viewport-input.md` | Document publication, viewport, and input boundaries. |
| iOS rendering and export | `swift-ios/rendering.md`, `swift-ios/export.md` | Presentation state and export representation. |
| C++ stroke engine | `stroke-engine/input-modeling.md`, `stroke-engine/geometry.md`, `stroke-engine/prediction-frames.md` | Shared stroke geometry and platform consumption. |
