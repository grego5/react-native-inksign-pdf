# Architecture contract

Cross-platform invariants and navigation to subsystem references.

The module is a Nitro/Fabric view for signing local, ordered PDFs. Native code
owns PDF I/O, viewport/input conversion, text and ink state, history, and
export; JavaScript sends commands and receives coarse state. One page is active
at a time, with page-local history containing committed ink and text.

Canonical geometry is PDF media-box-relative page units with a top-left origin
and positive Y down. View transforms and high-frequency geometry never enter
stored state or the JavaScript boundary.

## Reference map

| Area | Reference | Summary |
| --- | --- | --- |
| Public API | src/InkSignView.nitro.ts | Props, methods, and callbacks. |
| Android lifecycle/input | android/view-lifecycle.md, android/viewport-input.md | Ownership, readiness, transforms, navigation, and routing. |
| Android rendering/export | android/rendering-front-buffer.md, android/export.md | Presentation, prediction, vector ink, text, and artifacts. |
| iOS lifecycle/input | swift-ios/view-lifecycle.md, swift-ios/viewport-input.md | Ownership, readiness, modes, transforms, and routing. |
| iOS rendering/history/export | swift-ios/rendering.md, swift-ios/history.md, swift-ios/export.md | Live drawing, committed history, and source-preserving export. |
| C++ engine | stroke-engine/input-modeling.md, stroke-engine/geometry.md, stroke-engine/prediction-frames.md | Modeling, outlines, prediction, and platform frames. |

## Scope

- React Native New Architecture/Fabric with Nitro on iOS and Android.
- Local input/output paths; ordered PDF pages with one active page.
- Ink, text annotations, undo, redo, clear, and source-preserving signed-PDF
  export.
- Finger and stylus input; Android stroke width is velocity-driven, while iOS
  delegates pressure response to PencilKit.
- Deferred: erasers, highlights, images, form fields, other annotation types,
  raw stroke import/export, raster flattening, and ArrayBuffer PDF APIs.
- Out of scope: Paper, web, Windows, and macOS.

## Ownership and threading

- JavaScript owns composition, imperative commands, and coarse state. It never
  receives PDF bytes, points, or per-frame geometry.
- Native layers own document sessions, viewport/input conversion, text and ink
  presentation, page-local history, and export. Android uses the shared C++
  page-space outline engine; iOS uses PDFium/PencilKit, with PDFKit retained
  only for source metadata and export. Platform document
  resources and rendering work remain owned by their creating serial workers;
  worker handles and platform objects never enter JavaScript or returned
  snapshots.
- The shared `PdfiumPageAssembler` owns no publication state. On its caller's
  serial worker it applies one append, remove, or move command to copied
  working-PDF bytes, keeps all PDFium handles and staged JPEG bytes inside the
  operation, saves a non-incremental scratch candidate, and returns detached
  page metadata only after reopening and validating the candidate.
- All PDFium API calls, including initialization, destruction, session
  operations, rendering, inspection, and assembly, are serialized by the
  process-wide `PdfiumLibraryState::apiMutex`. Platform serial workers own
  session lifetime and ordering but do not replace this PDFium-wide guard;
  helpers called while it is held do not acquire it again.
- UI state and callbacks are main/UI-thread-owned. PDF parsing, tile rendering,
  and export run on serial workers. The C++ engine is synchronous, caller-owned,
  and independent of UIKit, Android, and React Native.
- Android document lifecycle and page mutation are coordinated by
  `MutableDocumentCoordinator`; see the Android lifecycle reference for
  ownership and transaction rules.
- Android and iOS text-field hints are immutable placement metadata. They stay
  outside content, history, dirty state, previews, export, and JavaScript.
- Any worker result carries only the platform generation, page index, and an
  immutable detached value snapshot. It does not carry native handles,
  pointers, worker-owned buffers, or platform containers.

## Public contract

- The authoritative API is src/InkSignView.nitro.ts.
- Props: strokeColor, strokeMinWidth, strokeMaxWidth, strokeSmoothing,
  defaultTextFontSize, defaultTextColor, outlineColor, selectedOutlineColor,
  editorBackgroundColor, selectedBackgroundColor, doubleTap,
  keyboardAvoidanceEnabled, onStateChange, and onPageChange.
- defaultTextFontSize uses canonical page units: invalid values use 16 and
  valid values are clamped to 8...72. defaultTextColor is captured as opaque
  RRGGBB content color only for new annotations. Outline and editor/background
  colors are presentation-only; an unspecified editor fill contrasts with the
  saved text color. doubleTap configures an absolute zoom target, default 2.0,
  and optional edit-mode entry.
- Methods: open, addPages, removePage, movePage, nextPage,
  previousPage, getViewport, enterEditMode, enterViewMode, undo, redo, clear,
  insertAnnotationOn, insertAnnotationOff, increaseTextSize,
  decreaseTextSize, removeTextAnnotation, and finalize. Android debug builds
  also expose the debug-recording methods defined in the TypeScript spec.
- `PageType` is `pdf` or `image`. `addPages(options?)` accepts both types when
  omitted, appends selected files in picker order, expands every selected PDF
  in source order, and appends one page per image. Cancellation resolves with
  zero added pages and leaves the active page and state unchanged.
- `removePage()` removes the active page and activates the page now at its
  index, or the preceding page when the removed page was last; the final page
  cannot be removed. `movePage(pageIndex)` accepts a destination in
  `0..<pageCount`, shifts intervening pages, and keeps the moved page active.
  Structural mutations are outside page-local undo/redo and mark the document
  dirty after successful publication.
- The document must be ready for page mutation. Only one page-input staging or
  structural mutation may be active; conflicting operations reject with
  `operation_in_progress`, and open/disposal cancel pending work with
  `operation_cancelled`. Invalid move destinations reject before mutation.
- insertAnnotationOn settles current editing, preserves the viewport, and arms
  exactly one valid page tap; it does not create content or open the keyboard.
  The next valid tap creates one native draft, disables placement, focuses its
  editor, and opens the keyboard. insertAnnotationOff is idempotent and clears
  only unconsumed placement. Empty drafts disappear without history; committed
  text and deletion share page history with ink.
- Text uses explicit newlines and intrinsic longest-line sizing. Font size is
  annotation-local canonical data, so zoom changes presentation only. Native
  text gestures remain outside PDF pan, zoom, ink, and page navigation.
  JavaScript receives only coarse onStateChange snapshots; text commands throw
  with text_not_focused when no selection is live.
- getViewport returns the constrained canonical page center and absolute zoom.
  It is synchronous and read-only, requires a live document and usable layout,
  and throws when the view is not ready.
- Viewport snapshots are application-owned bookmark data; the module provides
  capture and restoration only and owns no bookmark registry or persistence.
- enterEditMode and enterViewMode accept optional viewport options. Omitted
  options preserve focus/zoom; an empty object fits and centers; paired x/y
  focuses that page point; and zoom alone preserves focus. Coordinates must be
  paired. Invalid values are rejected before mutation; focus is clamped to the
  page and zoom to 0.1...16. Resolution means mapping and mode are ready, not
  that asynchronous tiles have finished.
- onStateChange reports canUndo, canRedo, isDirty, and mode:
  view, draw, textPlacement, textSelected, or textEditing. open and page
  opening returns PageInfo; navigation is an imperative command whose committed
  result is reported by onPageChange. The mode prop and InkSignPdfMode type are
  absent; mode changes are imperative and throw validation errors synchronously.
  Boundary navigation is a successful no-op; superseded turns cancel silently;
  onPageChange fires only after a real page switch is installed, never for open,
  cancellation, or viewport changes.

## Cross-platform invariants

- open invalidates prior generation/work, installs page zero in view mode, fits
  and centers by default, and does not emit onPageChange. Page switches are
  generation-bound and emit only after a usable target mapping is installed.
- Before a stroke, validate and freeze its page transform/configuration. A
  successful end appends once to page history; cancellation discards only live
  presentation. Prediction is disposable and never enters history or export.
- finalize snapshots immutable committed content on the UI thread and exports
  on a worker. It preserves source pages, never overwrites the source, and
  never exports live or predicted geometry. Android preserves vector ink/text;
  iOS preserves the source PDF with committed text and PencilKit ink.
- View mode owns navigation and edit mode owns drawing. Page turns require a
  matching current preview; stale callbacks cannot commit or install state.
- Disposal is idempotent: invalidate generations, cancel active state, clear
  presentation/callbacks, close worker resources, and reject stale work.
