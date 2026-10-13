# iOS PDFium backend and headless document core

Use PDFium 157.0.8086.0 for iOS source analysis, page assembly, and finalized
content, then give iOS the Android ownership boundary: a document core with
optional PDFKit presentation. Keep CoreText/UIKit editing and PencilKit input.
Implement the existing headless and state APIs on iOS; preserve their shapes.

## Execution

| Order | Task | Status |
| --- | --- | --- |
| 01 | [Package PDFium and establish the bridge](Tasks/01-pdfium-package-bridge.md) | Complete (static) |
| 02 | [Import canonical PDFium analysis](Tasks/02-canonical-source-analysis.md) | Complete (static) |
| 03 | [Return encoded image-page inputs](Tasks/03-image-page-inputs.md) | Complete (static) |
| 04 | [Replace structural PDFKit writing](Tasks/04-pdfium-document-assembly.md) | Complete (static) |
| 05 | [Extract the shared content writer](Tasks/05-shared-content-writer.md) | Complete (static) |
| 06 | [Prepare CoreText export resources](Tasks/06-coretext-export-resources.md) | Completed (static) |
| 07 | [Finalize through PDFium](Tasks/07-ios-pdfium-export.md) | Completed (static) |
| 08 | [Verify the PDFium backend checkpoint](Tasks/08-backend-checkpoint.md) | Prepared; user execution pending |
| 09 | [Extract the headless document core](Tasks/09-headless-document-core.md) | Planned |
| 10 | [Align committed text, fonts, and history](Tasks/10-committed-content-parity.md) | Planned |
| 11 | [Bind handles and expose the headless API](Tasks/11-core-handles-headless-api.md) | Planned |
| 12 | [Attach viewer presentation through changes](Tasks/12-viewer-document-adapter.md) | Planned |
| 13 | [Verify headless parity and final contracts](Tasks/13-headless-integration-verification.md) | Planned |
| 14 | [Support session tags and targeted page lookup](Tasks/14-session-page-tags.md) | Planned |
| 15 | [Share prepared rotation projections and pairing](Tasks/15-prepared-rotation-parity.md) | Planned |
| 16 | [Close recent Android contract and ownership gaps](Tasks/16-recent-android-parity-verification.md) | Planned |

Tasks 01-08 establish the backend; Tasks 09-13 extract ownership and align public
behavior. Tasks 14-16 cover recent Android parity additions without reopening
completed work. Task 08 is the backend interoperability checkpoint before the
broader refactor; Task 13 verifies the base architecture and Task 16 the appended
contracts. Tests and builds remain
prohibited until explicit user authorization. Source inspection and
`git diff --check` are allowed. Record a deferred checkpoint as unverified.

Temporary incompatible interfaces and broken intermediate builds are accepted.
Do not add compatibility facades or duplicate state to keep each step green.
They must be resolved by final integration. Runtime acceptance requires both
checkpoints and the appended parity checks; accepting intermediate breakage does
not authorize execution.

## Reviewed decisions

- Reuse existing implementations, then move document FIFO, lifecycle, stable
  page/target IDs, committed content, analysis, fonts, export, and artifacts into
  one Swift core. The backend owns resources, not a second logical document.
- Remove PDFDocument/PDFPage and active selection from document/page state.
  PDFKit objects, selection, drafts, focus, gestures, and readiness are viewer-owned.
- Core publication completes independently of presentation. Viewer adapters
  consume changes and may additionally await their own readiness.
- Shared PDFium analysis now returns canonical geometry and orthogonal rules.
  Reuse it on iOS without repeating PDFKit's display-to-canonical conversion.
- The image encoder currently returns a PDFKit page. Return JPEG bytes and page
  placement instead, preserving its raster sizing and quality policy.
- CoreText already shapes iOS text. Export its positioned glyphs rather than
  reshaping them with HarfBuzz. Android retains HarfBuzz; both use the same PDF
  embedding, Unicode mapping, and vector-content writer.
- Export adopts Android's embedded page-content model, replacing iOS locked
  module annotations. Preserve source content and visible source annotations;
  do not claim byte-identical output or broader PDF semantics.
- Use the published Apple archive. Verify symbol/font compatibility before
  declaring export accepted; do not rebuild Android archives for this plan.
- PDFKit remains the renderer. Existing viewport and input defects are separate
  from backend acceptance. Retain the interaction/viewport owners.
- Analysis comes from authoritative working/candidate PDFium data. Unchanged
  source pages retain stable-ID snapshots through structural rewrites; neither
  old originals nor PDFKit extraction are an alternative source of truth.
- Match current getState/event shapes and untracked/base-content semantics.
  Viewer cores record history; headless cores do not, matching Android. This
  policy is fixed at construction and is not changed by presentation attachment.
- Enable Swift headless Nitro bindings and named fonts; preserve method shapes.
  No new public viewer-attachment API, multi-view sharing, or renderer is included.

## Final ownership

| Owner | Responsibilities |
| --- | --- |
| Document core | Command admission/FIFO, lifecycle, ordered IDs, committed content/targets/history, analysis/font caches, dirty state, export, cleanup |
| PDFium backend | Queue-owned document/page/font resources, reads, assembly, serialization; immutable results to the core |
| Viewer adapter | Active page, PDFKit document/pages, presentation leases/caches, viewport, interaction, drafts, selection, focus, animations, event projection |

Headless and viewer adapters submit the same document operations. Synchronous
page operations read/edit published state; only async work uses the shared FIFO.
Mode authorization is checked by viewer wrappers and never becomes core state.

Tasks 01-05 are implemented with static inspection only. Remaining tasks are planned;
backend linkage and runtime acceptance remain deferred under the user restriction.

