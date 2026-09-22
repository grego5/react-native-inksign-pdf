# Task 05b: Centralize iOS operations and export snapshots

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Prepare the Task 6 mutation boundary by making the iOS coordinator the sole owner of operation admission, artifacts, dirty state, and export snapshots. Preserve the current public behavior; structural commands arrive in Task 6.

## Depends on

- [Task 05a](05a-establish-ios-coordinator-ownership.md)

## Implementation

1. Route open and finalize through one coordinator operation boundary. Reserve one active operation, reject conflicting work, and keep generation checks at publication. Define the same boundary for Task 6's picker staging and structural commands without implementing those commands here.
2. Move working/output artifact tracking and exact cleanup to the coordinator. Keep picker UI and staging in `InkSignPdfPageInputCoordinator`; staged inputs transfer to the coordinator only when a structural operation is admitted.
3. Have the coordinator capture an immutable export snapshot of the current working PDF, ordered pages, and committed ink/text content. The export worker must use only that snapshot; publication must reject stale or disposed generations and clean failed output artifacts.
4. Aggregate page-history dirty state in the coordinator and reserve independent structural dirty state for Task 6. Keep undo/redo page-local. Ensure open, cancellation, replacement, and disposal settle pending work and artifacts once.

## Regression expectations

- Finalize remains non-consuming and preserves source PDF content and page markup. Export neither commits live input nor reads changing view state on its worker.
- Concurrent or canceled operations leave the published document intact; stale completions cannot publish output or leak files.

## Completion

- Add focused tests for admission, cancellation, stale export, dirty aggregation, and artifact cleanup. Update the iOS lifecycle/export references and run focused iOS lifecycle and export validation plus `git diff --check -- ':!nitrogen/generated/**'`.

Status: Planned
