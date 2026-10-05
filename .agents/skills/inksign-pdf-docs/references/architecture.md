# Architecture overview

React Native InkSign PDF is a Fabric/Nitro view for signing ordered local PDF
documents. JavaScript composes the screen and sends commands; native code owns
document bytes, page presentation, input conversion, committed content, history,
and export.

## System boundaries

- The public contract lives in
  [`src/InkSignView.nitro.ts`](../../../../src/InkSignView.nitro.ts). JavaScript
  receives coarse state/page events plus prepared-page text metadata and text
  selection IDs, not PDF data or per-frame geometry.
- [`src/index.ts`](../../../../src/index.ts) validates public arguments before
  native dispatch. Platforms check document-dependent bounds when admitting a
  command; loaders validate PDF, image, and OS data at ingress.
- Text uses canonical top-left page points. Direct insertion clips complete
  lines to its flow bounds; manual placement applies the same options to its
  editor and committed text. The editor admits fitting input, allows deletion,
  and retains text through reflow. Committed text stores its resolved direction
  and flow options. See the platform input and export references for layout rules.
- `addPages()` selects the current, first added, or last added page through
  `activePage`; the default keeps the current page, or selects the first page
  when creating a document. Empty and cancelled imports leave document state
  unchanged.
- Image imports use configurable DPI and JPEG quality, with defaults of 200 DPI
  and 0.72. Rasterization preserves page aspect ratio; explicit DPI is capped
  by source resolution. PDF inputs retain their original pages.
- Each platform coordinator owns one published document with an ordered stable
  page list, one active page, and page-local committed history. Android uses
  PDFium for document I/O; iOS uses PDFKit with Quartz and CoreText. The UI
  thread owns presentation and callbacks.
- Each platform backend prepares, validates, and publishes its own detached
  candidate as one document transition.
- Each mounted view owns an independent document coordinator and operation
  session. See [document operations](#document-operations) for replacement,
  cancellation, and promise settlement.
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
  the native overlay owns live drafts and selection. IDs are scoped to one view
  and remain monotonic across document opens. Prepared operations are synchronous
  after asynchronous page preparation and continue to address the captured page.
  Module text takes precedence over embedded source text; clearing module text
  leaves the PDF source intact. Field lookup matches complete labels by token
  frequency, so word order may vary while partial labels and repeated-word
  mismatches do not match.
- Stored geometry uses canonical page coordinates: media-box-relative with a
  top-left origin. Viewport transforms are presentation-only.
- Opens and page mutations prepare detached candidates. Failed or cancelled
  page mutations leave the current document intact. Caller source files are
  never overwritten.
- Finalize exports an immutable snapshot of committed content from the current
  working document to a separate output. It does not consume or replace the
  working document.

## Document operations

- The coordinator owns session identity, pending document operations, and
  cancellation for its view. Each operation captures its session and request
  identity when admitted.
- An accepted `open()` invalidates the previous session, cancels its pending
  opens, imports, page mutations, text lookups, navigation, viewport requests,
  and document exports, and clears the previous document's presentation and
  input state. Debug recording export remains independent of document replacement.
  Replacement proceeds even when those operations are active.
- Opening waits internally for document loading and usable presentation geometry.
  Only the latest accepted open may install a document. Its promise resolves
  after complete installation; state and page callbacks describe that document.
  A current open failure leaves the view empty. A superseded open cannot clear
  or restore a newer session.
- Check operation identity on the owning thread before publishing mutations,
  emitting asynchronous callbacks, and settling promises. Superseded successes
  and failures reject with `operation_cancelled`; each promise settles once.
  A result already settled before replacement cannot be withdrawn.
- Cancellation prevents further publication immediately. A worker may finish its
  current serialized request before the queue closes its reader or deletes its
  temporary files; cleanup follows worker ownership even after its promise has
  been cancelled.
  Unpublished outputs are retired. Finalized outputs remain view-owned until
  disposal, as described in the platform export references.
- Disposal invalidates the session, cancels pending operations, clears callbacks
  and presentation, and releases resources through the same cleanup rules.
- Android's optional `androidFallbackFont` contains the app-shared local `uri`,
  HTTP(S) fallback `url`, and optional collection index. Android reuses a valid
  file at `uri` or downloads and atomically publishes `url` there. The app owns
  the shared file and its invalidation; iOS uses system font fallback.
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
