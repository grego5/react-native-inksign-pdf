# 13 - Verify headless parity and final contracts

[Plan](../TASKS.md)

Status: Simulator complete; physical-device acceptance pending
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

## Current integration

DocumentCoreTests covers headless edit/export/close, FIFO close draining, independent base history, atomic fonts/source aliases, and page/target/tag identity across import/reorder/rotation. Its full run passed four cases and timed out in close draining; that case passed in isolation. The full core gate remains pending.

Current export and placement-analysis suites passed. The page-state history test passed after correcting fixture page selection. Live editor width now uses TextKit line widths instead of a caret rectangle from the previous layout. All four focused direction-switch, short-text, complete-line, and snapping checks passed. Complete-line assertions use retained laid-out lines; snapping assertions convert through the current presentation transform. Logs: `review-direction-draft-exact.log`, `review-short-text-width.log`, and `review-two-text-options.log` on the authorized Mac test host. Broader viewer lifecycle/navigation and Android shared-code validation remain outstanding.

## Lifecycle follow-up verification

Full core (5) and navigation (3) suites passed. Focused coordinate cancellation, rejected/no-op draft preservation, caret visibility, and immediate-close checks passed. Reader-lease cleanup passed through retention and release/deletion. Three serial runs of each immediate-close/replacement case passed (9 executions) with a 60-second two-view completion deadline; the first two-view run needed 54.943 seconds on the VM. Prompt cancellation retained its 2-second assertion. Temporary core-load traces were removed. A final full lifecycle/text run and Android shared-code validation remain pending.

## Final simulator integration results

Current-source lifecycle passed 45/45 and text interaction passed 49/49 across the final two runs. Core passed 5/5 and PDF navigation passed 3/3. Artifact ownership checks use a controlled worker barrier; addPages completion allows 120 seconds for Mac VM overhead (observed 57.281 seconds). No production timing policy changed. Lifecycle log: `integration-final-lifecycle-class-rerun.log`; text log: `integration-final-lifecycle-text-interaction.log`. Android crop-coordinate validation and physical iOS presentation checks remain unverified.

## Structural correction follow-up

Core structural publication owns replaced-file retirement; reader leases protect retained presentation. Open settlement has no rollback state or success flag. Removal/movement share core preflight before viewer suspension and at FIFO execution. Authored whitespace passed; current-source compilation and focused headless/lifecycle/artifact checks remain pending for these corrections. Earlier passing suites predate this change.

## Completion boundary

Structural corrections compiled and passed core 5/5 plus focused lifecycle 7/7. The core completion watchdog is 120 seconds; it measures no performance requirement. Implementation and simulator acceptance are complete. Physical iOS presentation and deferred Android shared-code validation remain outside the completed boundary. No full cross-platform/device acceptance claim is made.
