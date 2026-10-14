# iOS PDFium backend and headless document core

Use PDFium 157.0.8086.0 for iOS source analysis, page assembly, and finalized
content, then use the shared ownership boundary: a document core with
optional PDFKit presentation. Keep CoreText/UIKit editing and PencilKit input.
Implement the existing headless and state APIs on iOS; preserve their shapes.

## Execution

| Order | Task | Status |
| --- | --- | --- |
| 01 | [Package PDFium and establish the bridge](Tasks/01-pdfium-package-bridge.md) | Complete |
| 02 | [Import canonical PDFium analysis](Tasks/02-canonical-source-analysis.md) | Complete |
| 03 | [Return encoded image-page inputs](Tasks/03-image-page-inputs.md) | Complete |
| 04 | [Replace structural PDFKit writing](Tasks/04-pdfium-document-assembly.md) | Complete |
| 05 | [Extract the shared content writer](Tasks/05-shared-content-writer.md) | Complete |
| 06 | [Prepare CoreText export resources](Tasks/06-coretext-export-resources.md) | Complete |
| 07 | [Finalize through PDFium](Tasks/07-ios-pdfium-export.md) | Complete |
| 08 | [Verify the PDFium backend checkpoint](Tasks/08-backend-checkpoint.md) | Complete (iOS checkpoint) |
| 09 | [Extract the headless document core](Tasks/09-headless-document-core.md) | Complete |
| 10 | [Align committed text, fonts, and history](Tasks/10-committed-content-parity.md) | Complete |
| 11 | [Bind handles and expose the headless API](Tasks/11-core-handles-headless-api.md) | Complete |
| 12 | [Attach viewer presentation through changes](Tasks/12-viewer-document-adapter.md) | Complete |
| 13 | [Verify headless parity and final contracts](Tasks/13-headless-integration-verification.md) | Simulator complete; device acceptance pending |
| 14 | [Support session tags and targeted page lookup](Tasks/14-session-page-tags.md) | Complete |
| 15 | [Share prepared rotation projections and pairing](Tasks/15-prepared-rotation-parity.md) | Complete |
| 16 | [Close recent Android contract and ownership gaps](Tasks/16-recent-android-parity-verification.md) | Implementation complete; remaining acceptance deferred |
| 17 | [Review and align imported-page geometry compatibility](Tasks/17-page-geometry-compatibility.md) | iOS validated; Android/device checks pending |

Tasks 01-08 establish the backend; Tasks 09-13 extract ownership and align public
behavior. Tasks 14-16 cover recent Android parity additions without reopening
completed work. Task 08 is the backend interoperability checkpoint before the
broader refactor; Task 13 verifies the base architecture and Task 16 the appended
contracts. Tests/builds run only through the user-authorized validation chat
`01a12c88-60f1-7500-85a4-10ff730af7a2`; the implementation chat performs source
inspection and `git diff --check`. Record unexecuted checkpoints as unverified.

Task 17 follows the current refactor. Review Android and iOS geometry behavior
before selecting a shared compatibility contract; existing Android behavior is
not a constraint on the final design. The selected visible-page contract and implementation are recorded in Task 17;
its native/runtime validation remains pending.

Temporary incompatible interfaces and broken intermediate builds are accepted.
Do not add compatibility facades or duplicate state to keep each step green.
They must be resolved by final integration. Runtime acceptance requires both
checkpoints and the appended parity checks.

## Reviewed decisions

- Neither platform defines the shared API contract. Discoveries on Android or
  iOS may expose gaps in either implementation; choose the intended behavior
  from requirements and backend capabilities, then align both platforms.
- Reuse existing implementations, then move document FIFO, lifecycle, stable
  page/target IDs, committed content, analysis, fonts, export, and artifacts into
  one Swift core. The backend owns resources, not a second logical document.
- Remove PDFDocument/PDFPage and active selection from document/page state.
  PDFKit objects, selection, drafts, focus, gestures, and readiness are viewer-owned.
- Core publication completes independently of presentation. Viewer adapters
  consume changes and may additionally await their own readiness.
- Shared PDFium analysis now returns canonical geometry and orthogonal rules.
  Reuse it on iOS without repeating PDFKit's display-to-canonical conversion.
- The image encoder returns JPEG bytes and page placement, preserving raster
  sizing and quality policy.
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

The iOS implementation and simulator integration are complete. Current-source
checks passed: core 5, navigation 3, text interaction 49, lifecycle 45; structural
corrections subsequently passed core 5 and focused lifecycle 7. Export and
analysis gates passed; public API checks passed 22. VM completion deadlines are
hang watchdogs, not performance requirements. Physical iOS presentation acceptance
and Android shared crop-coordinate validation remain deferred; Task 17 reviews
both platforms before further geometry changes. Full cross-platform/device
acceptance is not complete.

