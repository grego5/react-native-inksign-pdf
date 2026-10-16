# 05 — Focused regression verification

[Plan index](../TASKS.md)

Status: Dispatched to authorized verification chat — results pending
Complexity: Medium
Depends on: 01–04

## Objective / non-goals

Verify native selection, lifetime, and existing direct imports through predictable
observable invariants. Use controlled native selection/provider completions and
real local PDF/image fixtures; assess actual system UI separately. No broad
gesture, renderer, performance, or combinatorial input matrix.

## Read before editing

- `tools/view-ref.test.cjs`: public wrapper/headless dispatch harness.
- `ios/tests/DocumentCoreTests.swift`, `ImagePageEncoderTests.swift` and restored
  input coordinator test seams from Task 03.
- Android `DocumentCoordinatorTest.kt`, `HybridInkSignViewCreatePagesTest.kt`,
  Task 02 input registrar/result seam; locate current packages with `rg`.
- `tools/test-android.ps1`, the external `vmac` adapter, package scripts.
- Maintainer `development.md`: source freshness, host execution, validation scope.

## Invariants to preserve

Document work completes at publication without a viewer. Direct sources work
without foreground UI. Imports preserve source bytes, selected page identity,
history policy, tags, encoding settings, and existing text transaction behavior
on cancellation/failure. Source files belong to callers; staging belongs to native.

## Add/update focused coverage

1. **Public wrapper dispatch:** call exported `createDocument()`/`addPages()` with omitted
   inputs and with explicit sources; assert native factory/owner arguments and
   results. Lifecycle-cancelled imports remain recognizable by `isOperationCancelled`.
   Exercise dispatch, not standalone guard predicates.
2. **Headless selection success:** controlled native picker returns an ordered PDF
   and small non-JPEG image. First import creates pages in that order; append adds all
   pages to an existing owner without constructing a viewer. Assert count, one
   distinguishing content/geometry fact per source, and tags. Explicit sources
   bypass presentation, including when no activity/controller is available.
3. **Cancellation/failure preserves data:** with existing module text/history and
   an admitted text edit, cancel append. Assert zero added/current count, same
   text/history and no structural event. For a type mismatch or one unreadable
   selected source, assert complete rejection and no partial import. Check request
   staging is empty after completion; caller source files remain readable.
4. **FIFO and close:** hold selection with a controllable completion, queue another
   mutation, and assert it cannot publish ahead of selection. Close while waiting:
   selection rejects, queued picker UI never launches, and close finishes after
   already-selected/direct-source work drains. Release an obsolete callback and
   assert it cannot mutate data, settle twice, or claim a newer request.
   Use barriers/completions, with generous hang watchdogs rather than speed assertions.
5. **Provider lifetime:** on iOS, complete image providers out of order and remove
   their temporary source URLs after the coordinator's copy contract; imported order
   and reopening remain correct. On Android, deliver content URIs through the result
   seam and verify unregister/release and owned copies after provider access ends.
   Across both, concurrent presentation on another owner rejects without losing
   the original picker. No foreground presenter yields `missing_presenter`.
6. **Presentation independence:** detach a viewer while selection is waiting, then
   complete import; the original owner updates and can reattach. Successful append
   preserves an attached viewer's selected stable page. Confirm initial picking in
   the example works before mounting a viewer and subsequent Add pages needs no
   Expo package.

Extend existing fixtures where suitable. Put Android platform-result/provider checks
in `android/src/androidTest/kotlin/com/margelo/nitro/inksignpdf/PageInputCoordinatorInstrumentationTest.kt`
and iOS delegate/provider checks in `ios/tests/PageInputCoordinatorTests.swift`.
Keep core FIFO/close assertions in existing coordinator/core fixtures where possible.
Update old required-options initializers after generation. Share small fixtures/helpers
instead of creating a separate test per filter value or decoder format.

## Validation execution

Tests/builds remain prohibited in the implementation chat. Send the focused scope
to authorized verification chat `01a12c88-60f1-7500-85a4-10ff730af7a2`; do not wait,
poll, or read its chat. Process incoming results and fix demonstrated defects.
Commands below are for that verification context or a later user-authorized run:

```powershell
npm run nitrogen
npm run test:public-api
npx tsc --noEmit --pretty false
tools\test-android.ps1 -Mode jvm -Test com.margelo.nitro.inksignpdf.DocumentCoordinatorTest
tools\test-android.ps1 -Mode build -Abi arm64-v8a
tools\test-android.ps1 -Mode connected -Abi arm64-v8a -Test com.margelo.nitro.inksignpdf.PageInputCoordinatorInstrumentationTest
tools\test-android.ps1 -Mode connected -Abi arm64-v8a -Test com.margelo.nitro.inksignpdf.HybridInkSignViewCreatePagesTest
git diff --check
```

Select `x86_64` instead when using that emulator ABI; record the actual target.
Run focused iOS tests with the externally configured `ios-runner` MCP; it snapshots
and verifies source before testing. Use `status` and `logs` to record test counts,
snapshot ID, SDK/device, outcome, and runner termination separately. A successful
compile/zero-test run does not establish behavior; slow VM completion is not a
latency regression.

```js
run_tests({ project: 'inksignpdf', tests: ['PageInputCoordinatorTests', 'DocumentCoreTests', 'ImagePageEncoderTests'] });
```

From Windows, use `vmac test inksignpdf` with class/method selectors or
`vmac test inksignpdf --build-only` for test-artifact compilation. The adapter
profile owns the Mac scripts and configured scheme/destination.

Manual system UI checks: PDF/image/mixed filtering, Files/Photos source choice on
iOS, multi-selection order, Back/cancel, iPad popover placement, and host teardown.
Missing device, foreground UI, SDK, or Mac evidence remains a named gap.

## Completion / proposed commit

Additional regression pending execution: `DocumentCoreTests/testQueuedPickerStartsOnlyAfterPreviousPickerDismisses()`
holds the native dismissal completion. Empty Photos selection must keep the first
request unsettled and the next FIFO picker unpresented until dismissal completes;
the second request must then start and cancel normally without adding pages.

Dispatched on 2026-10-16 to `01a12c88-60f1-7500-85a4-10ff730af7a2` for
regression additions and execution against the connected Samsung and trusted Mac.
No tests or builds ran in the implementation chat. Nitrogen generation succeeded;
authored `git diff --check` excluding generated output passes. Five whitespace
warnings remain in generated Swift bridge/options output. Native compilation,
regression results, and manual system UI checks remain pending; dispatch establishes
no passing result. TypeScript MCP-LSP could not resolve this repository's project;
Kotlin reference discovery returned no matches, so focused source inspection supplied
the implementation evidence rather than treating incomplete LSP output as validation.

Record results and remaining gaps here. Complete only when stable regressions
pass, native resources retire, direct imports remain usable, and relevant manual
checks are recorded or explicitly left pending. Keep the plan status truthful.

Commit: `test: verify native picker ownership and document imports`
