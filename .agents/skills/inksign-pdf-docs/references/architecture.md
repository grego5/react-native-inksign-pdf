# Architecture overview

React Native InkSign PDF is a Fabric/Nitro view for signing ordered local PDF
documents. JavaScript composes the screen and sends commands; native code owns
document bytes, page presentation, input conversion, committed content, history,
and export.

## System boundaries

- The public contract lives in
  [`src/InkSignView.nitro.ts`](../../../../src/InkSignView.nitro.ts). JavaScript
  receives coarse state and page events, not PDF data or per-frame geometry.
- Public method arguments are validated once by the host component in
  [`src/index.ts`](../../../../src/index.ts) before native dispatch. Native
  method implementations consume those validated arguments directly. A move
  command's upper page bound depends on live document state, so each platform
  checks it when admitting the command. PDF, image, and OS data are checked at
  their respective ingress boundaries.
- Both platforms implement `addTextAnnotation(text, position, options?)` in
  canonical top-left page points without opening the editor. Direction-aware
  wrapping uses `xLimit` or the page edge. `yLimit` and `maxLines` retain only
  complete lines; `verticalAnchor` fixes the top or bottom edge of the visible
  block. `insertAnnotationOn(options?)` applies the same flow options from its
  tap point. A bounded editor admits edits that fit its region and line limit,
  while deletion stays available. Reflow from direction or font-size changes
  preserves entered text. Direct insertion clips to the flow region. Omitting
  placement options retains tap-centered, rule-aware placement. Save resolved
  direction and flow metadata with committed text; manual placement resolves
  direction when armed.
- Both platforms accept `activePage` in `addPages()` to choose `current`,
  `firstAdded`, or `lastAdded` within the detached structural candidate.
  Omission and `current` preserve the active page for an existing document;
  creating a document selects its first added page. Empty and cancelled imports
  leave page count and active page unchanged.
- `addPages()` image inputs use per-call `targetDpi` and `jpegQuality` when set.
  `targetDpi` defaults to 200 DPI and `jpegQuality` to 0.72. Raster size is
  limited to 8192 pixels on its longest edge; supplied DPI is also capped by
  the source image's resolution at contain fit. Raster dimensions scale
  together to preserve the page aspect ratio. PDF inputs retain their original
  pages.
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
- Opening prepares a module-owned candidate while the current presentation
  remains usable. A current open failure clears the published document before
  rejection; a superseded attempt cannot change a newer open. Page mutations
  prepare and validate a detached candidate, and failed, cancelled, or stale
  mutations leave the published document in place. The caller's source is
  never overwritten.
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
