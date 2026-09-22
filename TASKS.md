# Native file picker and mutable PDF pages

Extend `InkSignView` into a native mutable-document editor. Users can append
selected PDF and image files, remove the current page, move the current page,
continue editing ink and text on every surviving page, and finalize the current
ordered document. File/image import and caller-provided scanner output use the
same page-staging and assembly pipeline.

## Public contract

- `addPages(options?)` opens native selection UI and always appends successful
  selections to the end of the document.
- `addPages({ sources })` imports the supplied ordered local paths or file URLs
  without presenting a picker. Scanner packages can use this mode after they
  finish writing their cache files.
- `options.type` is optional and accepts `pdf` or `image`. Omission permits
  both. One action may select multiple files; every selected PDF contributes
  all of its pages and every selected image contributes one page.
- `removePage()` removes the current page. A document must retain at least one
  page.
- `movePage(pageIndex)` moves the current page to the zero-based destination
  index. Intervening pages shift; it is not a swap operation.
- After either operation, the first newly appended page becomes active. A
  canceled operation leaves the previous active page unchanged.
- `removePage()` rejects removal of the final remaining page; the document
  always contains at least one page.
- PDF bytes, selected-file copying, image conversion, document mutation, and
  export stay native. JavaScript receives only promises and coarse page/state
  metadata.

## Constraints

- Copy the caller-owned PDF into a module-owned working PDF during `open` and
  use that working PDF for rendering, page mutation, and export. The original
  remains read-only and is never a live document source after open completes.
- Preserve PDF pages as PDF content; do not rasterize imported PDF pages.
- Normalize each selected image into one white-background page using the
  current page dimensions, corrected orientation, and aspect-fit placement.
- Give every native page stable identity independent of its current index so
  ink and text history follows a moved page and is discarded only when that
  page is removed.
- Structural mutations are not added to page-local undo/redo in this scope.
- Keep one active page and all existing page-space, threading, cancellation,
  source-preservation, and generated-file rules unless a task explicitly
  replaces them.
- Do not edit `nitrogen/generated/**` manually.

## Canonical architecture

Each platform has one `MutableDocumentCoordinator` as the sole owner of the
working PDF, ordered `PageRecord` collection, current page ID, document
generation, and operation state. A `PageRecord` has a stable native ID and owns
that page's ink and text state; its index is always derived from collection
position.

The native file picker or caller-provided sources return an ordered list of
module-owned staged inputs. Image normalization converts one staged image into
  one optimized staged JPEG. Reuse the proven implementation in
  `C:\dev\react-native-images-to-pdf` with EXIF orientation enabled, white
  background, `contain` fit on the target page, 200 target DPI, and JPEG quality
  0.72 only when re-encoding is required.
The shared `PdfiumPageAssembler` accepts the current working PDF plus one
structural command and produces a candidate PDF. It creates image pages with
PDFium image objects and inline JPEG data; the platform encoder supplies only
the optimized JPEG bytes and placement geometry. The coordinator validates and
opens the candidate, atomically replaces the working document and render
session, then deletes the retired artifact. The view delegates commands to the
coordinator and renders its published state; it does not mutate page arrays or
manage files independently.

`addPages`, `removePage`, `movePage`, `open`, and `finalize` all enter the same
serialized coordinator boundary. There is no second structural state model,
no optional pre-mutation source mode, and no platform-specific PDF mutation
path.

Every PDFium API call is additionally serialized by the process-wide shared
`PdfiumLibraryState::apiMutex`, including initialization, destruction,
rendering, inspection, session close, and assembly. Platform workers own
session lifetime and ordering but must not introduce per-document PDFium locks;
helpers called while the shared guard is held must not acquire it again.

## Implementation policy

- Prefer replacing index-owned and immutable-document structures over wrapping
  them with compatibility layers. Breaking internal and public changes are
  acceptable when they make the ownership model coherent.
- Encode invariants in types and ownership: one coordinator, one working PDF,
  one ordered page collection, one active operation. Do not scatter defensive
  checks that compensate for ambiguous ownership or partially updated state.
- Fail at the operation boundary for invalid caller input or unsupported
  source data. Treat an impossible internal state as an implementation defect;
  do not recover with guessed indexes, silent no-ops, or fallback files.
- Publish a mutation only after its candidate PDF and replacement render
  session are complete. Transactional publication is the correctness model,
  not a collection of rollback patches after partial mutation.
- Keep task implementations direct and complete. Do not add temporary adapters,
  compatibility aliases, placeholder native methods, or duplicate pipelines to
  preserve the previous architecture.

## Task order

1. [Establish the mutable-page public contract](Tasks/01-establish-mutable-page-contract.md)
2. [Add shared PDFium page assembly](Tasks/02-add-pdfium-page-assembly.md)
3. [Add the Android file picker and staging boundary](Tasks/03-add-android-file-picker.md)
4. [Add the iOS file picker and staging boundary](Tasks/04-add-ios-file-picker.md)
5. [Integrate mutable pages on Android](Tasks/05-integrate-android-mutable-pages.md)
6. [Integrate mutable pages on iOS](Tasks/06-integrate-ios-mutable-pages.md)
7. [Document and validate the complete workflow](Tasks/07-document-and-validate-page-workflow.md)

Tasks 3 and 4 may proceed after Task 1. Task 5 depends on Tasks 1 through 3;
Task 6 depends on Tasks 1, 2, and 4. Task 7 depends on all prior tasks.
