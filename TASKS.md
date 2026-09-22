# Native file picker and mutable PDF pages

Extend `InkSignView` into a native mutable-document editor. Users can create a
document from selected PDF and image files or append them to an existing one,
remove the current page, move the current page,
continue editing ink and text on every surviving page, and finalize the current
ordered document. File/image import and caller-provided scanner output use the
same page-staging and assembly pipeline.

## Public contract

- `addPages(options?)` opens native selection UI. It creates a document when
  none exists and otherwise appends successful selections to the end.
- `addPages({ sources })` imports the supplied ordered local paths or file URLs
  without presenting a picker. Scanner packages can use this mode after they
  finish writing their cache files.
- `options.type` is optional and accepts `pdf` or `image`. Omission permits
  both. One action may select multiple files; every selected PDF contributes
  all of its pages and every selected image contributes one page.
- `options.imagePageSize` supplies width and height in PDF points for imported
  images. Without it, images use the active page dimensions when a document
  exists and portrait A4 (595.28 × 841.89 points) when creating one. The size
  applies to all images in the action, including mixed PDF/image selections.
- Cancellation or empty `sources` leaves the document unchanged and resolves
  with `addedPageCount: 0`. `pageInfo` is omitted only when no document exists;
  otherwise it reports the unchanged active page.
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
  resolved image page size, corrected orientation, and aspect-fit placement.
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
The shared `PdfiumPageAssembler` accepts an optional current working PDF plus
one creation or structural command and produces a candidate PDF. It creates image pages with
PDFium image objects and inline JPEG data; the platform encoder supplies only
the optimized JPEG bytes and placement geometry. The coordinator validates and
opens the candidate, atomically replaces the working document and render
session, then deletes the retired artifact. The view delegates commands to the
coordinator and renders its published state; it does not mutate page arrays or
manage files independently.

`addPages`, `removePage`, `movePage`, `open`, and `finalize` all enter the same
serialized coordinator boundary. There is no second structural state model or
platform-specific PDF mutation path. Creation is an explicit assembler
command; append, remove, and move require an existing working PDF.

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
5a. [Establish iOS coordinator ownership](Tasks/05a-establish-ios-coordinator-ownership.md)
5b. [Centralize iOS operations and export snapshots](Tasks/05b-centralize-ios-operations.md)
6. [Integrate mutable pages on iOS](Tasks/06-integrate-ios-mutable-pages.md)
6a. [Extend the create-or-append public contract](Tasks/06a-create-or-append-contract.md)
6b. [Create PDFs from staged pages in shared PDFium assembly](Tasks/06b-create-pdf-from-pages.md)
6c. [Create documents through addPages on Android](Tasks/06c-android-create-from-pages.md)
6d. [Create documents through addPages on iOS](Tasks/06d-ios-create-from-pages.md)
6e. [Preserve Android documents during replacement open](Tasks/06e-android-transactional-open.md)
7. [Document and validate the complete workflow](Tasks/07-document-and-validate-page-workflow.md)

Tasks 3 and 4 may proceed after Task 1. Task 5 depends on Tasks 1 through 3.
Task 5a depends on Task 1 and may proceed alongside Tasks 2, 4, and 5.
Task 5b depends on Task 5a. Task 6 depends on Tasks 2, 4, and 5b.
Task 6a depends on Task 1. Task 6b depends on Tasks 2 and 6a. Task 6c depends
on Tasks 5 and 6b; Task 6d depends on Tasks 6 and 6b. Task 6e depends on Task 5
and may proceed alongside Tasks 6a through 6d. Task 7 depends on all prior tasks.
