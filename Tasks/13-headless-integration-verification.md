# 13 - Verify headless parity and final contracts

[Plan](../TASKS.md)

Status: Planned
Complexity: High
Depends on: 09-12 and backend checkpoint 08

## Objective and non-goals

Prove the final API/ownership works without constructing a view, adapt the viewer
integration, and document current contracts. Tests/builds remain prohibited until
explicit authorization. Accepted intermediate breakage must be resolved here;
do not hide it behind compatibility shims or infer success from static checks.

## Read before editing

- Final core, history, handles, backend, and viewer adapter from Tasks 09-12.
- `src/InkSignDocument.nitro.ts`, `InkSignView.nitro.ts`, `index.ts`, `nitro.json`.
- Existing Android headless/history/state cases: locate focused classes with rg.
- `ios/tests/InkSignViewLifecycleTests.swift`, `InkSignViewTextInteractionTests.swift`,
  `InkSignViewPDFNavigationTests.swift`, and backend cases from Task 08.
- `tools/test-ios-lifecycle.ps1`, `tools/test-ios-mac-vm.sh`, public API runners,
  package/artifact verification, and the current example callers.
- Maintainer architecture, iOS lifecycle/history/export/input references, and
  `references/development.md`; README methods/headless examples.

## Meaningful regression work

Use fixed fixtures and stable invariants. Reuse the backend cases rather than
duplicating them through every adapter. Do not introduce timing or gesture pixel
tolerances to force green results.

| Boundary | Expected result |
| --- | --- |
| Headless workflow | openDoc, getState/getPage, resolve/read/edit text, loadFonts, add/reorder/rotate/remove pages, finalize, and close work with no InkSignView/PDFView/overlay/window allocated. Export is readable and visibly correct. |
| Commit before presentation | Core data mutation settles while a controlled viewer presentation is delayed. The core queue advances; headless success does not wait for PDFKit. The viewer-specific caller still awaits its own readiness. |
| Handle identity | A captured page retains ID through reorder/navigation/rotation and reports new index/geometry. Deletion/replacement/close rejects stale access; page disposal does not close its document. |
| Local authorization | Superseded mode-scoped handles reject; ordinary core-bound handles remain valid. Closing a document cancels both kinds without late mutation/publication. |
| State/event shapes | Reads match current shared types. Imported PDF text/ink does not set session hasText/hasInk. Public page events are smaller and deduplicate reported fields; viewer events combine global state with mode/error/pageIndex. |
| Untracked history | A viewer untracked target is clean/exportable and survives unrelated ink/text undo/redo. A retained tracked identity, including redo-only or grouped-clear history, forces tracked treatment. Undo to the beginning is clean. |
| Headless policy | Headless content edits use base without undo/dirty; structural changes dirty the document. Internal presentation attachment does not change policy or committed content. |
| Fonts/values | Preloaded names resolve synchronously with identical preview/export resources; failed batch loading is atomic. Core values use module/source/empty precedence; viewer draft precedence is local. |
| Resource lifetime | Close is terminal/idempotent, lets earlier admitted commands finish, and rejects new calls immediately. Running native work retains resources after cancellation; leases/observers/candidates retire once. Headless successful outputs survive close. |

1. Add focused headless/core regressions that allocate no view. Use controllable
   backend/presentation completions for queue/cancellation invariants rather than
   sleeps or helper-only predicates. Inspect exported text and PDFKit rendering.
2. Adapt existing iOS history/page/state callers to the final API. Remove obsolete
   getInfo/hasInk/resetDirty/revision assumptions and Android-only rejection cases
   where iOS now supports the feature. Keep retained platform-specific resource
   expectations. Preserve all meaningful backend checks from Task 08.
3. Update public wrapper/factory dispatch coverage for iOS without tests repeating
   straightforward guards. Check that headless wrappers dispatch real methods,
   return current states, and do not create React/native views.
4. Static ownership review: no core reference to InkSignView/PDFView/overlay/mode
   tokens; no PDFDocument/PDFPage/active selection in committed state; no viewer
   history store or duplicate document FIFO. CoreText/PKDrawing are permitted
   native layout/content types and do not themselves require a mounted viewer.
5. Check default/failed initialization, callback reentry, export cleanup, and
   observer/lease retirement. A retained page/selected-text handle must not keep
   a disposed viewer/document resource alive indefinitely.

## Deferred execution

Once explicitly authorized, use the documented Mac workflow, source hashes,
exact nonempty selectors, and narrow core/headless/lifecycle/export focuses.
Refresh Pods only for changed native inputs. Run applicable public API/TypeScript
checks and focused Android parity cases after shared/spec changes. Confirm actual
executed counts and preserve meaningful failure artifacts.

Use a physical iOS device for final presentation fidelity: field focus, multiline
editing, keyboard/caret motion, ink, structural changes, and exported rendering.
Separate prior interaction defects from refactor regressions. Unavailable hosts,
devices, font formats, or backend gates remain unverified; the VM is not a
performance benchmark. Neither this file nor the index grants execution permission.

## Documentation and completion

- Rewrite shared/iOS references as current contracts: core owns data/FIFO/history/
  analysis/fonts/export; backend owns worker resources; viewer owns active page,
  PDFKit objects and interaction. Cross-reference formulas instead of repeating
  implementation stories. Document commit versus presentation completion.
- Describe shared getState/event payloads, scoped versus ordinary handles,
  untracked/base history, fixed headless history policy, source-analysis lifetime,
  and output ownership. Remove superseded platform-only and original-copy claims.
- Update artifact metadata, licensing, package source maps, and native verification.
  README remains a quick method guide with a short headless usage example.
- Regenerate bindings if final authoritative specs changed; never hand-edit them.
  Run `git diff --check` and inspect the example for removed methods/options.
- All intermediate interface breakage is resolved. Report implemented/static/
  runtime/unavailable separately; full acceptance requires Task 08 plus a complete
  headless workflow and optional viewer integration. No custom renderer or new
  public document-sharing/attachment API is introduced.
- Proposed commit: `test(ios): verify headless parity and document-core contracts`.
