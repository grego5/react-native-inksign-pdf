# Architecture overview

React Native InkSign PDF is a Fabric/Nitro view for signing ordered local PDF
documents. JavaScript composes the screen and sends commands; native code owns
document bytes, page presentation, input conversion, committed content, history,
and export.

## System boundaries

- The public contract lives in
  [`src/InkSignView.nitro.ts`](../../../../src/InkSignView.nitro.ts). JavaScript
  receives coarse state and page events, not PDF data or per-frame geometry.
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
- Document operations are coordinated per view. Worker results are accepted
  only while their document and request remain current.
- Android renders PDFium tiles beneath native annotation presentation and uses
  the shared C++ stroke engine. iOS renders PDFKit pages through Quartz and
  uses PencilKit for ink input; export retains source pages and adds committed
  text and filled vector signatures as PDF annotations.

## Document model

- Page order and active-page identity are document state. Ink and text are
  committed per-page content; active gestures, predictions, editor drafts, and
  selection are temporary presentation state.
- Stored geometry uses canonical page coordinates: media-box-relative with a
  top-left origin. Viewport transforms are presentation-only.
- Opens and page mutations prepare detached candidates. A current open failure
  clears the document; failed, cancelled, or stale page mutations leave it in
  place. Superseded work cannot replace newer state, and source files are never
  overwritten.
- Finalize exports an immutable snapshot of committed content from the current
  working document to a separate output. It does not consume or replace the
  working document.

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
