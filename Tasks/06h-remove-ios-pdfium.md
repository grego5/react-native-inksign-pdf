# Task 06h: Remove PDFium from the iOS product

Back to task index: [TASKS.md](../TASKS.md)

## Objective

Delete the superseded iOS PDFium runtime, bridge, exporter, tests, packaging,
and documentation after every iOS PDF operation has moved to the native backend.

## Depends on

- [Task 06d](06d-ios-create-from-pages.md)
- [Task 06g](06g-restore-native-ios-rendering-export.md)

## Implementation

1. Remove the iOS PDFium session and Objective-C++ bridge, iOS-only PDFium
   exporter integration, PDFium-backed page view, smoke tests, and dead adapter
   entry points. Preserve Android PDFium sources and symbols.
2. Remove PDFium libraries, headers, resources, build settings, verification,
   and podspec inputs from the iOS package. Confirm a clean consumer does not
   download, compile, embed, or link PDFium for iOS.
3. Remove dual-session state, compatibility adapters, feature flags, and stale
   fallback errors. The coordinator must expose one native document lifecycle.
4. Update focused tests to assert public behavior and the native preservation
   contract. Delete tests that exist only to preserve PDFium bridge structure or
   obsolete dual-engine behavior.
5. Add a repository check preventing new production iOS references to PDFium
   while allowing the Android backend to continue using it.

## Completion

- The iOS target and distributed pod contain no PDFium binary, header, bridge,
  runtime symbol, or packaging step.
- Android PDFium build, mutation, rendering, and export tests remain green.
- iOS native lifecycle, fixture interoperability, simulator, example build,
  and device archive validation pass.

Status: In progress; macOS feature-gate results and external-viewer evidence are
pending before this removal can be considered complete.
